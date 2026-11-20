param(
  [Parameter(Mandatory)][string]$Config,
  [Parameter(Mandatory)][string]$Arch,
  [Parameter(Mandatory)][string]$Preset,
  [Parameter(Mandatory)][string]$Workspace
)

# Arma el paquete que se publica como artefacto:
#   - MuServer/ (ini, DATA, SQL) copiado tal cual del repo
#   - los cuatro .exe en su carpeta, como los espera el .ini
#   - mu-data.exe (con MSVC sale en el árbol de build, no en bin/)
#   - CRT dinámico de JoinServer/DataServer + script de configuración
#
# No usa here-strings dentro del workflow: ese fue el error que dejó el YAML
# inválido (una línea con 2 espacios de sangría cerraba el bloque y GitHub no
# instanciaba ningún job).

$ErrorActionPreference = 'Stop'

$serverRoot = Join-Path $Workspace 'server'
$bin        = Join-Path $serverRoot "Source/MuServer/bin/$Config"
$stage      = Join-Path $Workspace 'artifact'

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# 1) Configuración y datos de runtime que ya viven en el repo.
Copy-Item -Path (Join-Path $serverRoot 'MuServer/*') -Destination $stage -Recurse -Force

# 2) Ejecutables.
Copy-Item -LiteralPath (Join-Path $bin 'ConnectServer/ConnectServer.exe') -Destination (Join-Path $stage 'ConnectServer') -Force
Copy-Item -LiteralPath (Join-Path $bin 'GameServer/GameServer.exe')       -Destination (Join-Path $stage 'GameServer') -Force
Copy-Item -LiteralPath (Join-Path $bin 'MYSQL/JoinServer/JoinServer.exe')  -Destination (Join-Path $stage 'MySQL/JoinServer') -Force
Copy-Item -LiteralPath (Join-Path $bin 'MYSQL/DataServer/DataServer.exe')  -Destination (Join-Path $stage 'MySQL/DataServer') -Force

# 3) mu-data: sin RUNTIME_OUTPUT_DIRECTORY propio en MSVC.
$buildRoot = Join-Path $serverRoot "out/build/$Preset"
$muData = Get-ChildItem -Path $buildRoot -Recurse -Filter 'mu-data.exe' -ErrorAction SilentlyContinue |
          Select-Object -First 1
if (-not $muData) { throw "mu-data.exe no apareció en $buildRoot" }
Copy-Item -LiteralPath $muData.FullName -Destination $stage -Force

# 4) CRT dinámico: JoinServer/DataServer son /MD (ver mu_add_server).
#    ConnectServer/GameServer/mu-data son /MT y no lo necesitan.
if ($Config -eq 'Release') {
    $dllRoot = if ($Arch -eq 'x86') { Join-Path $env:WINDIR 'SysWOW64' } else { Join-Path $env:WINDIR 'System32' }
    foreach ($dir in @((Join-Path $stage 'MySQL/JoinServer'), (Join-Path $stage 'MySQL/DataServer'))) {
        foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            $srcDll = Join-Path $dllRoot $dll
            if (Test-Path -LiteralPath $srcDll) { Copy-Item -LiteralPath $srcDll -Destination $dir -Force }
        }
    }
}

# 5) Script de configuración.
$fixScript = @'
param(
  [string]$Address = '127.0.0.1',
  [int]$Port = 55901,
  [string]$Version = '0.97.45'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$startup = Join-Path $root 'GameServer/DATA/GameServerInfo - StartUp.dat'
$text = Get-Content -LiteralPath $startup -Raw
$text = [regex]::Replace($text, '(?m)^ServerVersion\s*=.*$', "ServerVersion=$Version")
Set-Content -LiteralPath $startup -Value $text -NoNewline -Encoding utf8

$list = Join-Path $root 'ConnectServer/ServerList.dat'
$lines = Get-Content -LiteralPath $list
$new = foreach ($line in $lines) {
  if ($line -match '^\s*\d+\s') {
    $line = $line -replace '"[0-9]{1,3}(\.[0-9]{1,3}){3}"', ('"' + $Address + '"')
    $line = $line -replace '(?<=\t)\d{4,5}(?=\t)', $Port.ToString()
  }
  $line
}
Set-Content -LiteralPath $list -Value $new -Encoding utf8

Write-Host "ServerVersion=$Version  ServerList=${Address}:${Port}"
'@
Set-Content -LiteralPath (Join-Path $stage 'fix-config.ps1') -Value $fixScript -Encoding utf8

# 6) Instrucciones.
$readme = @'
MuServer 0.97.45 - Windows (artefacto de GitHub Actions)

Contenido
  ConnectServer/       ConnectServer.exe + ConnectServer.ini + ServerList.dat
  GameServer/          GameServer.exe + DATA/ (TOML y .dat de configuracion)
  MySQL/JoinServer/    JoinServer.exe + JoinServer.ini
  MySQL/DataServer/    DataServer.exe + DataServer.ini
  MySQL/DB/            CreateDatabase.sql, PoblateDatabase.sql, ...
  mu-data.exe          importar/comparar datos desde .txt/.dat
  fix-config.ps1       ajusta ServerVersion y ServerList

Puesta en marcha
  1. Crear la base: MySQL/DB/CreateDatabase.sql y despues PoblateDatabase.sql.
  2. Revisar las credenciales de MySQL en MySQL/JoinServer/JoinServer.ini y
     MySQL/DataServer/DataServer.ini.
  3. .\fix-config.ps1 -Address 127.0.0.1   (o la IP publica)
  4. Orden de arranque: DataServer -> JoinServer -> ConnectServer -> GameServer.
  5. Puertos: 44405/TCP y 55601/UDP (ConnectServer), 55901/TCP (GameServer).
     El firewall de Windows tiene que permitirlos.
  6. La primera vez, GameServer genera Data/Keys/ServerIdentity.key; el
     ConnectServer solo lo lee. Se necesita el mismo archivo en los dos.

Runtime de C
  ConnectServer, GameServer y mu-data: CRT estatico (/MT), no piden DLL.
  JoinServer y DataServer: CRT dinamico (/MD); el paquete trae msvcp140.dll,
  vcruntime140.dll y vcruntime140_1.dll al lado de cada .exe. Si Windows igual
  los rechaza, instalar "Visual C++ 2015-2022 Redistributable".

Notas
  - No incluye mu-trace: ese target solo existe en Linux (/dev/shm).
  - ServerVersion=0.97.45 y protocolo 13 tienen que coincidir con el cliente.
  - Debug se entrega sin DLL del CRT de depuracion a proposito: es para probar
    en la maquina de desarrollo, no para distribuir.
'@
Set-Content -LiteralPath (Join-Path $stage 'README-ARTIFACT.txt') -Value $readme -Encoding utf8

# 7) Verificación dura.
$must = @(
    (Join-Path $stage 'ConnectServer/ConnectServer.exe'),
    (Join-Path $stage 'GameServer/GameServer.exe'),
    (Join-Path $stage 'MySQL/JoinServer/JoinServer.exe'),
    (Join-Path $stage 'MySQL/DataServer/DataServer.exe'),
    (Join-Path $stage 'mu-data.exe')
)
foreach ($p in $must) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Falta: $p" }
    $kb = [math]::Round((Get-Item -LiteralPath $p).Length / 1KB, 1)
    Write-Host "OK  $(Split-Path -Leaf $p)  $kb KB"
}

$total = (Get-ChildItem -LiteralPath $stage -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("Paquete: " + [math]::Round($total / 1MB, 1) + " MB en $stage")

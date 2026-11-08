<#
.SYNOPSIS
  Schaltet Equalizer APO zwischen Messkonfiguration (flach) und EQ-Konfiguration um.

.BESCHREIBUNG
  -Modus Messen : sichert die aktuelle config.txt nach config\backup_eq_<datum>.txt
                  (und zusaetzlich als config\letzte_eq.txt) und kopiert
                  pc\eqapo_messen.txt (Preamp 0 dB, keine Filter) nach config.txt.
  -Modus EQ     : stellt config\letzte_eq.txt wieder her. Mit -Datei <pfad> wird
                  stattdessen diese Datei (z. B. ein Vorschlag aus analyze.py) als
                  neue config.txt eingesetzt; die bisherige wird vorher gesichert.
  -Modus Status : zeigt, was gerade aktiv ist.

  Equalizer APO liest config.txt bei jeder Aenderung sofort neu, ein Neustart ist
  nicht noetig. Das Skript muss aus einem normalen PowerShell-Fenster laufen
  (nicht aus einer Sandbox), damit der Audiodienst die Datei wirklich sieht.

.BEISPIELE
  .\eqapo_toggle.ps1 -Modus Messen
  .\eqapo_toggle.ps1 -Modus EQ
  .\eqapo_toggle.ps1 -Modus EQ -Datei ..\messungen\2026-11-15\analyse\eqapo_vorschlag.txt
  .\eqapo_toggle.ps1 -Modus Status
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Messen", "EQ", "Status")]
    [string]$Modus,

    [string]$Datei,

    [string]$ConfigDir = "C:\Tools\EQ_APO\config"
)

$ErrorActionPreference = "Stop"
$configTxt = Join-Path $ConfigDir "config.txt"
$letzteEq  = Join-Path $ConfigDir "letzte_eq.txt"
$messen    = Join-Path $PSScriptRoot "eqapo_messen.txt"

if (-not (Test-Path $configTxt)) { throw "config.txt nicht gefunden: $configTxt" }

function Ist-Messkonfig([string]$pfad) {
    $inhalt = Get-Content $pfad -Raw
    return $inhalt -match "MESSKONFIGURATION"
}

function Sichere-Config {
    if (Ist-Messkonfig $configTxt) { return }   # Messkonfig nie als EQ sichern
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backup = Join-Path $ConfigDir "backup_eq_$stamp.txt"
    Copy-Item $configTxt $backup
    Copy-Item $configTxt $letzteEq -Force
    Write-Host "EQ-Konfig gesichert: $backup"
}

switch ($Modus) {
    "Status" {
        if (Ist-Messkonfig $configTxt) { Write-Host "Aktiv: MESSEN (flach)" }
        else { Write-Host "Aktiv: EQ"; Get-Content $configTxt | Where-Object { $_ -and $_ -notmatch "^\s*#" } }
    }
    "Messen" {
        Sichere-Config
        Copy-Item $messen $configTxt -Force
        Write-Host "Aktiv: MESSEN (flach). Zusaetzlich pruefen: Sound-Blaster-Effekte (SBX, Crystalizer, Bass) aus, Windows-Lautstaerke notieren."
    }
    "EQ" {
        if ($Datei) {
            if (-not (Test-Path $Datei)) { throw "Datei nicht gefunden: $Datei" }
            Sichere-Config
            Copy-Item $Datei $configTxt -Force
            Copy-Item $Datei $letzteEq -Force
            Write-Host "Aktiv: EQ aus $Datei"
        }
        elseif (Test-Path $letzteEq) {
            Copy-Item $letzteEq $configTxt -Force
            Write-Host "Aktiv: EQ (letzte_eq.txt wiederhergestellt)"
        }
        else {
            throw "Keine gesicherte EQ-Konfig vorhanden (letzte_eq.txt fehlt). Erst -Modus Messen ausfuehren oder -Datei angeben."
        }
    }
}

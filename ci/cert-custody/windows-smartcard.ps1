# Windows smart card (A3) custody tests (WI-2026-11-22-001). An emulated PIV card (PivApplet on
# jCardSim) sits behind the vsmartcard virtual reader; its key is generated on the card, its
# certificate comes from the test CA, and Windows reaches it through the inbox PIV minidriver
# and the Smart Card KSP. Runs elevated on a GitHub Actions Windows runner.
# Usage: windows-smartcard.ps1 -Fixtures DIR -Applet DIR
param([Parameter(Mandatory)][string]$Fixtures, [Parameter(Mandatory)][string]$Applet)
$ErrorActionPreference = 'Stop'
trap { Write-Host "::error file=ci/cert-custody/windows-smartcard.ps1,line=$($_.InvocationInfo.ScriptLineNumber)::$($_.Exception.Message -replace '\r?\n',' | ')"; break }
$PSNativeCommandUseErrorActionPreference = $true
$work = (New-Item -ItemType Directory -Force (Join-Path $env:RUNNER_TEMP 'smartcard')).FullName
$pin = '123456' # PivApplet default
$openssl = "$env:ProgramFiles\Git\usr\bin\openssl.exe"

# Runs a native tool; on failure the error carries its output, since only annotations are public.
function Invoke-Tool([string]$Exe) {
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & $Exe @args 2>&1 | ForEach-Object { "$_" }
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Exe) $($args -join ' ') exited $LASTEXITCODE`: $(($out | Select-Object -Last 8) -join ' | ')" }
}

function Expand-Msi([string]$Url, [string]$Name) {
    # Administrative extraction: the tools without installing their drivers or minidrivers.
    Invoke-WebRequest $Url -OutFile "$work\$Name.msi"
    $p = Start-Process msiexec -Wait -PassThru -ArgumentList "/a `"$work\$Name.msi`" /qn TARGETDIR=`"$work\$Name`""
    if ($p.ExitCode -ne 0) { throw "extracting $Name failed: $($p.ExitCode)" }
}

# 1. Virtual reader (test-signed UMDF driver; its certificate must be trusted first).
Invoke-WebRequest https://github.com/frankmorgner/vsmartcard/releases/download/virtualsmartcard-0.11/virtualsmartcard-win-x64.zip -OutFile "$work\vsc.zip"
Expand-Archive "$work\vsc.zip" "$work\vsc"
certutil -f -addstore Root "$work\vsc\BixVReader.cer" | Out-Null
certutil -f -addstore TrustedPublisher "$work\vsc\BixVReader.cer" | Out-Null
$p = Start-Process msiexec -Wait -PassThru -ArgumentList "/i `"$work\vsc\BixVReaderInstaller.msi`" /qn /norestart /L*v `"$work\vsc-install.log`""
if ($p.ExitCode -ne 0) { Get-Content "$work\vsc-install.log" -Tail 60; throw "virtual reader install failed: $($p.ExitCode)" }
Set-Service SCardSvr -StartupType Automatic
Start-Service SCardSvr
Get-PnpDevice -Class SmartCardReader -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String | Write-Host

# 2. Card management tools.
Expand-Msi https://github.com/OpenSC/OpenSC/releases/download/0.27.1/OpenSC-0.27.1_x64.msi opensc
Expand-Msi https://developers.yubico.com/yubico-piv-tool/Releases/yubico-piv-tool-2.7.3-win64.msi ykpiv
$opensc = (Get-ChildItem -Recurse "$work\opensc" -Filter opensc-tool.exe | Select-Object -First 1).FullName
$ykpiv = (Get-ChildItem -Recurse "$work\ykpiv" -Filter yubico-piv-tool.exe | Select-Object -First 1).FullName

# 3. The card: PIV applet on jCardSim, connected to the virtual reader's TCP port.
$jc = Start-Process java -PassThru -WorkingDirectory $Applet -RedirectStandardOutput "$work\jcardsim.out" -RedirectStandardError "$work\jcardsim.err" `
    -ArgumentList '-cp', 'piv-applet;jcardsim.jar', 'com.licel.jcardsim.remote.VSmartCard', 'jcardsim.cfg'
try {
    $reader = $null
    $PSNativeCommandUseErrorActionPreference = $false # opensc-tool exits 1 while no card is present
    foreach ($i in 1..60) {
        $line = & $opensc --list-readers 2>$null | Where-Object { $_ -match '^\s*(\d+)\s+Yes\s+(.*\S)\s*$' } | Select-Object -First 1
        if ($line -and $line -match '^\s*(\d+)\s+Yes\s+(.*\S)\s*$') { $reader = @{ Nr = $Matches[1]; Name = $Matches[2] }; break }
        Start-Sleep 1
    }
    if (-not $reader) {
        $readers = (& $opensc --list-readers 2>&1 | Out-String) -replace '\r?\n', ' | '
        $pnp = (Get-PnpDevice -Class SmartCardReader -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FriendlyName)=$($_.Status)" }) -join ', '
        $jcerr = (Get-Content "$work\jcardsim.err", "$work\jcardsim.out" -ErrorAction SilentlyContinue | Select-Object -Last 5) -join ' | '
        throw "no reader shows the emulated card; readers: $readers; PnP: $pnp; jCardSim: $jcerr"
    }
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "card in reader $($reader.Nr): $($reader.Name)"

    # Instantiate the applet, then generate the key on the card and certify it with the test CA.
    Invoke-Tool $opensc -r $reader.Nr --send-apdu 80b80000120ba000000308000010000100050000020F0F7f
    Invoke-Tool $ykpiv -r $reader.Name -a set-chuid -a set-ccc
    Invoke-Tool $ykpiv -r $reader.Name -s 9a -a generate -A RSA2048 -o "$work\card.pub"
    Invoke-Tool $ykpiv -r $reader.Name -s 9a -P $pin -a verify-pin -a request-certificate -S '/CN=akela-custody-card/' -i "$work\card.pub" -o "$work\card.csr"
    Invoke-Tool $openssl x509 -req -in "$work\card.csr" -CA "$Fixtures\ca.pem" -CAkey "$Fixtures\ca.key.pem" -CAcreateserial -days 30 -extfile "$Fixtures\issuer.ext" -out "$work\card.crt.pem"
    Invoke-Tool $openssl x509 -in "$work\card.crt.pem" -outform der -out "$work\card.crt.der"
    Invoke-Tool $ykpiv -r $reader.Name -s 9a -a import-certificate -i "$work\card.crt.pem"

    # 4. The certificate in the user's store, bound to the card key. Certificate propagation
    # does this on interactive desktops; on a headless runner, bind it explicitly.
    $thumb = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 "$work\card.crt.der").Thumbprint
    foreach ($i in 1..20) { if (Test-Path "Cert:\CurrentUser\My\$thumb") { break }; Start-Sleep 1 }
    if (Test-Path "Cert:\CurrentUser\My\$thumb") {
        Write-Host 'certificate propagated from the card'
    } else {
        certutil -f -user -addstore My "$work\card.crt.der" | Out-Null
        certutil -user -silent -csp 'Microsoft Smart Card Key Storage Provider' -repairstore My $thumb
    }

    $env:CUSTODY_FIXTURES = $Fixtures
    $env:CUSTODY_SMARTCARD_CERT = "$work\card.crt.der"
    $env:CUSTODY_SMARTCARD_PIN = $pin
    $PSNativeCommandUseErrorActionPreference = $false
    $out = cargo test --manifest-path "$PSScriptRoot\Cargo.toml" --test smartcard 2>&1 | ForEach-Object { "$_" }
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) {
        $out | Select-String 'panicked|FAILED|error' | Select-Object -First 20 | ForEach-Object { Write-Host "::error::$_" }
        throw 'smart card tests failed'
    }
} catch {
    Write-Host "::error file=ci/cert-custody/windows-smartcard.ps1,line=$($_.InvocationInfo.ScriptLineNumber)::$($_.Exception.Message -replace '\r?\n',' | ')"
    Get-Content "$work\jcardsim.out", "$work\jcardsim.err" -ErrorAction SilentlyContinue | Select-Object -Last 40
    throw
} finally {
    Stop-Process -Id $jc.Id -ErrorAction SilentlyContinue
}

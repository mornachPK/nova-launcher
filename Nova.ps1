param([switch]$CheckOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Nova.Core.ps1')
Add-Type -AssemblyName System.Windows.Forms
try {
    $cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'distribution.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.enabled -or -not $cfg.feedUrl) { throw '아직 배포 전인 시험판입니다. 운영자가 다운로드 주소와 게임 서버 주소를 확정해야 합니다.' }
    $feed=[Uri]$cfg.feedUrl
    if (-not $feed.IsAbsoluteUri -or $feed.Scheme -ne 'https') { throw 'HTTPS 배포 주소가 필요합니다.' }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $release=Invoke-RestMethod -Uri $feed -TimeoutSec 30
    $app=Join-Path $env:LOCALAPPDATA 'Modrinth App/Modrinth App.exe'
    if (-not(Test-Path -LiteralPath $app)) {
        [void][Windows.Forms.MessageBox]::Show('먼저 Modrinth App을 설치하고 본인의 Minecraft 계정으로 로그인해주세요. 설치가 끝나면 노바 실행을 다시 누르세요.','노바 처음 설치')
        Start-Process 'https://modrinth.com/app'
        exit 0
    }
    if ($release.server -notmatch '^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$' -or $release.server -match '^(localhost|127\.|0\.)') { throw '친구들이 접속할 게임 서버 주소가 아직 설정되지 않았습니다.' }
    $work=Join-Path $env:LOCALAPPDATA 'NovaClient'
    [void](New-Item -ItemType Directory -Path $work -Force)
    $binding=Join-Path $work 'instance.json'
    if (-not(Test-Path -LiteralPath $binding)) {
        Assert-NovaRelease $release (Join-Path $work 'validation-root')
        $pack=Join-Path $work ('Nova-'+$release.version+'.mrpack')
        if (-not(Test-Path -LiteralPath $pack) -or (Get-NovaHash $pack) -ne $release.mrpack.sha256) { Save-NovaFile $release.mrpack $pack }
        if ((Get-NovaHash $pack) -ne $release.mrpack.sha256) { throw '설치본 검증에 실패했습니다.' }
        Start-Process -FilePath $app -ArgumentList ('"'+$pack+'"')
        $answer=[Windows.Forms.MessageBox]::Show("Modrinth에서 새 NOVA 모드팩을 설치해주세요. 모드는 자동으로 다운로드됩니다.`n설치가 완료되면 모드팩의 '바로가기 만들기'로 바탕화면에 바로가기를 만드세요.`n준비가 끝났으면 확인, 나중에 하려면 취소를 누르세요.",'노바 첫 설치',[Windows.Forms.MessageBoxButtons]::OKCancel)
        if ($answer -ne 'OK') { exit 0 }
        $dialog=New-Object Windows.Forms.OpenFileDialog
        $dialog.Title='방금 만든 NOVA 모드팩 바로가기를 선택하세요';$dialog.Filter='Modrinth 바로가기 (*.lnk)|*.lnk'
        if($dialog.ShowDialog() -ne 'OK'){exit 0}
        $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($dialog.FileName)
        if ($shortcut.Arguments -notmatch '^modrinth://launch/instance/(local:[a-fA-F0-9-]{36})(?:\?.*)?$') { throw '지원되는 Modrinth 모드팩 바로가기가 아닙니다.' }
        $instanceId=$matches[1]
        $folder=New-Object Windows.Forms.FolderBrowserDialog
        $folder.Description='Modrinth의 폴더 열기로 확인한 새 NOVA 모드팩 폴더를 선택하세요. 기존 개인용 모드팩을 선택하지 마세요.'
        if($folder.ShowDialog() -ne 'OK'){exit 0}
        $root=$folder.SelectedPath
        Assert-NovaRelease $release $root
        if(Test-Path -LiteralPath (Join-Path $root '.nova-managed.json')) { throw '이미 등록된 폴더입니다.' }
        if ((Test-Path -LiteralPath (Join-Path $root 'saves')) -and @(Get-ChildItem -LiteralPath (Join-Path $root 'saves') -Force).Count -gt 0) { throw '월드가 있는 기존 폴더는 등록하지 않습니다. 새 NOVA 인스턴스를 선택하세요.' }
        foreach($f in @($release.files)) {
            $p=Assert-NovaPath $root $f.path
            if(-not(Test-Path -LiteralPath $p) -or (Get-NovaHash $p) -ne $f.sha256){throw "설치 파일이 맞지 않거나 다운로드가 아직 끝나지 않았습니다: $($f.path)"}
        }
        $consent=[Windows.Forms.MessageBox]::Show("이 새 NOVA 폴더의 배포 대상 파일을 앞으로 자동 업데이트합니다. 교체 전 백업하며 개인 설정 변경이 발견되면 중단합니다.`n선택한 폴더: $root`n등록할까요?",'노바 업데이트 등록',[Windows.Forms.MessageBoxButtons]::YesNo)
        if($consent -ne 'Yes'){exit 0}
        @{schema=1;pack='nova';version=$release.version;files=@($release.files|Select-Object path,sha256)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root '.nova-managed.json') -Encoding UTF8
        @{root=$root;id=$instanceId}|ConvertTo-Json|Set-Content -LiteralPath $binding -Encoding UTF8
        $desktop=[Environment]::GetFolderPath('Desktop')
        $lnkPath=Join-Path $desktop '노바 플레이.lnk'
        if (-not(Test-Path -LiteralPath $lnkPath)) {
            $lnk=(New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
            $lnk.TargetPath=$env:ComSpec;$lnk.Arguments='/c ""'+(Join-Path $PSScriptRoot 'Nova.cmd')+'""';$lnk.WorkingDirectory=$PSScriptRoot;$lnk.Save()
        }
    }
    $bindingData=Get-Content -LiteralPath $binding -Raw -Encoding UTF8|ConvertFrom-Json
    if($bindingData.id -notmatch '^local:[a-fA-F0-9-]{36}$'){throw '잘못된 모드팩 식별자입니다.'}
    $result=Invoke-NovaUpdate $bindingData.root $release $work
    if($CheckOnly){Write-Output $result;exit 0}
    $url='modrinth://launch/instance/'+$bindingData.id+'?server='+[Uri]::EscapeDataString($release.server)
    Start-Process -FilePath $app -ArgumentList ('"'+$url+'"')
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'노바 실행 확인')
    exit 1
}

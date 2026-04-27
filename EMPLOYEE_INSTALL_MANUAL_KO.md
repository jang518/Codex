# RDP Usage 직원 PC 설치 매뉴얼

이 문서는 직원 PC에서 RDP Usage 트레이 앱을 설치하고 자동 실행되도록 설정하는 방법입니다.

## 1. 설치 전 준비물

관리자는 직원에게 아래 정보를 전달합니다.

- 서버 주소: `http://192.168.0.200:8765`
- 접속 토큰: 관리자에게 받은 Token 값
- 직원 PC용 파일: `client` 폴더 전체

직원 PC에는 아래 파일들이 있어야 합니다.

```text
C:\RdpUsageTool\
  client\
    RdpUsageTray.ps1
    messages-ko.json
    Run-ClientHidden.vbs
    Run-Client.cmd
    Run-Client-Debug.cmd
    Install-ClientStartup.cmd
    Install-ClientStartup.ps1
    Uninstall-ClientStartup.cmd
    Uninstall-ClientStartup.ps1
```

## 2. 파일 복사

직원 PC에 아래 폴더를 만듭니다.

```powershell
C:\RdpUsageTool
```

관리자에게 받은 `client` 폴더를 아래 위치에 복사합니다.

```text
C:\RdpUsageTool\client
```

## 3. 첫 실행

PowerShell을 열고 아래 명령을 실행합니다.

```powershell
cd C:\RdpUsageTool
.\client\Run-Client.cmd
```

첫 실행 시 설정 창이 뜨면 아래 값을 입력합니다.

```text
Server URL: http://192.168.0.200:8765
Token: 관리자에게 받은 Token
Display Name: 본인 이름
```

입력 후 `Save`를 누릅니다.

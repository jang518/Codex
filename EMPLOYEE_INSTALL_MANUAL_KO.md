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

## 4. 정상 동작 확인

오른쪽 아래 트레이 영역에서 `RDP Usage` 아이콘을 확인합니다.

아이콘이 숨겨져 있으면 `^` 버튼을 눌러 숨겨진 아이콘을 확인합니다.

상태 창을 열려면:

```text
트레이 아이콘 더블클릭
```

또는:

```text
트레이 아이콘 우클릭 → Open
```

상태 창에서 아래 내용이 보이면 정상입니다.

- 현재 서버 PC 사용 여부
- 현재 접속 중인 사용자
- 접속한 PC 이름/IP
- 예약 목록

## 5. 자동 실행 설정

직원 PC를 껐다 켜도 앱이 자동 실행되도록 아래 명령을 한 번 실행합니다.

```powershell
cd C:\RdpUsageTool
.\client\Install-ClientStartup.cmd
```

성공하면 아래와 비슷한 메시지가 표시됩니다.

```text
RDP usage client startup installed for ...
Task name: RdpUsageClient
```

이후부터는 해당 Windows 사용자로 로그인할 때 RDP Usage 트레이 앱이 자동 실행됩니다.

## 6. 사용 방법

### 현재 사용 여부 확인

트레이 아이콘을 더블클릭하거나 우클릭 후 `Open`을 누릅니다.

상태가 `Available`이면 서버 PC를 사용할 수 있습니다.

상태가 `Busy`이면 누군가 접속 중입니다.

### 예약 만들기

상태 창에서 `New` 버튼을 누릅니다.

아래 정보를 입력합니다.

```text
Owner: 본인 이름
Start: 예약 시작 시간
End: 예약 종료 시간
Note: 작업 내용
```

예약 시간이 다른 사람과 겹치면 저장되지 않습니다.

### 예약 삭제

예약 목록에서 삭제할 예약을 선택한 뒤 `Delete`를 누릅니다.

## 7. 알림 정책

직원 PC에는 예약 알림이 뜨지 않습니다.

예약 알림은 서버 PC에만 표시됩니다.

직원 PC에서는 현재 사용 상태와 예약 목록만 확인합니다.

## 8. 자동 실행 제거

더 이상 자동 실행하지 않으려면 아래 명령을 실행합니다.

```powershell
cd C:\RdpUsageTool
.\client\Uninstall-ClientStartup.cmd
```

## 9. 문제 해결

### 앱이 실행되지 않을 때

아래 명령으로 디버그 모드 실행을 합니다.

```powershell
cd C:\RdpUsageTool
.\client\Run-Client-Debug.cmd
```

오류 메시지가 PowerShell 창에 표시됩니다.

### 서버 상태가 보이지 않을 때

설정의 `Server URL`이 서버 이름이 아니라 IP 주소로 되어 있는지 확인합니다.

권장값:

```text
http://192.168.0.200:8765
```

### 연결 테스트

PowerShell에서 아래 명령을 실행합니다.

```powershell
Test-NetConnection 192.168.0.200 -Port 8765
```

아래처럼 나오면 네트워크 연결은 정상입니다.

```text
TcpTestSucceeded : True
```

### 설정을 다시 입력하고 싶을 때

트레이 아이콘 우클릭 후 `Settings`를 누릅니다.

서버 주소, 토큰, 표시 이름을 다시 저장합니다.

## 10. 설치 체크리스트

- `C:\RdpUsageTool\client` 폴더가 있다.
- `Run-Client.cmd` 실행 후 트레이 아이콘이 보인다.
- `Settings`에 서버 URL, Token, Display Name을 저장했다.
- 상태 창에서 서버 사용 상태가 보인다.
- `Install-ClientStartup.cmd` 실행이 성공했다.
- PC 재시작 후 로그인했을 때 트레이 아이콘이 자동으로 보인다.

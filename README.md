# RDP Usage Tool

Windows 원격 데스크톱으로 공용 고성능 PC를 사용하는 팀을 위한 내부용 상태 확인/예약 도구입니다.

구성은 두 가지입니다.

- `server/RdpUsageAgent.ps1`: 대상 PC에서 실행되는 상태 에이전트
- `client/RdpUsageTray.ps1`: 직원 PC에서 실행되는 포터블 트레이 앱

현재 구현은 외부 패키지 없이 Windows PowerShell 5.1에서 바로 실행되도록 만들었습니다. 예약 저장소는 `server/data/agent-store.json` 파일을 사용합니다. SQLite 저장소로 바꾸려면 `server/RdpUsage.Common.psm1`의 저장소 함수만 교체하면 되도록 API 경계를 분리했습니다.

## 빠른 시작

### 1. 대상 PC 서버 에이전트 설치

대상 PC에서 관리자 권한 PowerShell을 열고:

```powershell
cd C:\Path\To\RdpUsageTool
.\server\Install-Agent.ps1 -Port 8765
```

PowerShell 실행 정책 때문에 `.ps1` 실행이 막히면 아래처럼 `.cmd` 래퍼를 실행합니다.

```powershell
.\server\Install-Agent.cmd -Port 8765
```

설치 스크립트는 다음을 수행합니다.

- `server/agent-config.json` 생성
- Windows 방화벽 인바운드 규칙 등록
- 부팅 시 자동 실행되는 예약 작업 `RdpUsageAgent` 등록

설치 후 출력되는 `Token` 값을 직원 PC 앱 설정에 입력합니다.

수동 실행만 원하면:

```powershell
.\server\Run-Agent.cmd
```

서버 파일을 교체한 뒤 에이전트만 다시 시작하려면:

```powershell
.\server\Restart-Agent.cmd
```

서버 PC 화면에 예약 알림을 띄우려면, 서버 PC에 로그인한 사용자 계정에서:

```powershell
.\server\Install-ServerNotifier.cmd
```

를 실행합니다. 이 작업은 로그인할 때 `RdpUsageServerNotifier`를 자동 실행하도록 등록합니다. 바로 테스트하려면 트레이 아이콘 우클릭 후 `Test Notification`을 누릅니다.
서버 알림 트레이는 `Run-ServerNotifierHidden.vbs`를 통해 PowerShell 창 없이 실행됩니다. 오류 메시지를 직접 보고 싶을 때만 `Run-ServerNotifier-Debug.cmd`를 사용합니다.

### 2. 직원 PC 트레이 앱 실행

직원 PC에서:

```powershell
.\client\Run-Client.cmd
```

직원 PC 부팅/로그인 때마다 자동으로 실행되게 하려면 직원 PC에서:

```powershell
.\client\Install-ClientStartup.cmd
```

를 한 번 실행합니다. 이 작업은 현재 Windows 사용자 로그인 시 `RdpUsageClient`를 자동 실행하도록 등록합니다. 자동 실행을 제거하려면 `.\client\Uninstall-ClientStartup.cmd`를 실행합니다.

첫 실행 시 다음을 입력합니다.

- Server URL: `http://대상PC이름:8765` 또는 `http://고정IP:8765`
- Token: 서버 설치 시 생성된 토큰
- Display Name: 예약 목록에 표시할 직원 이름

앱은 작업 표시줄 트레이에 상주하며 상태를 주기적으로 확인합니다. 직원 PC 앱은 예약 알림을 띄우지 않습니다. 예약 알림은 서버 PC의 `RdpUsageServerNotifier`가 담당합니다.

`Run-Client.cmd`는 `Run-ClientHidden.vbs`를 통해 PowerShell 창을 남기지 않고 트레이 앱을 백그라운드로 띄웁니다. 오류 메시지를 직접 보고 싶을 때만 `Run-Client-Debug.cmd`를 사용합니다.

## API

모든 API는 `X-Rdp-Token` 헤더 또는 `Authorization: Bearer <token>` 헤더가 필요합니다.

- `GET /health`
- `GET /status`
- `GET /reservations`
- `POST /reservations`
- `DELETE /reservations/{id}`
- `POST /clients/heartbeat`

예약 생성 예시:

```json
{
  "owner": "Kim",
  "startUtc": "2026-04-22T01:00:00Z",
  "endUtc": "2026-04-22T02:00:00Z",
  "note": "CAD 작업",
  "clientId": "client-guid"
}
```

## 테스트

예약 충돌 정책 테스트:

```powershell
.\tests\Run-UnitTests.ps1
```

## 메모리 사용량 확인

서버 PC 또는 직원 PC에서 아래 명령으로 이 도구가 사용하는 메모리를 확인할 수 있습니다.

```powershell
cd C:\RdpUsageTool
.\tools\Get-RdpUsageMemory.ps1
```

또는:

```powershell
.\tools\Get-RdpUsageMemory.cmd
```

## 운영 메모

- Windows 10/11 Pro의 RDP 동시 접속 제한을 변경하지 않습니다.
- 예약은 직원 간 조율용이며 실제 접속 차단 기능은 없습니다.
- 종료 시간이 지난 예약은 직원 PC의 예약 목록에서 다음 새로고침 때 자동으로 사라집니다.
- 예약 알림은 서버 PC에 로그인된 사용자 세션에서 실행되는 `RdpUsageServerNotifier`가 표시합니다.

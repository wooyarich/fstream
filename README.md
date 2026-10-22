# FStream 2.0 (Apple Silicon Native)

원본 `FStream 1.4.9`(`x86_64`)의 미니 플레이어 UI(`MyPlugin` 스킨, 반원형 팝업/볼륨 버튼, 창 그림자, 전광판 스크롤)를 그대로 복원하고, Apple Silicon(`arm64`) 및 최신 macOS의 `Network` / `AudioToolbox` 프레임워크 기반으로 새롭게 구현한 인터넷 라디오 플레이어입니다.

## 다운로드 (바로 실행)

- **[Releases 페이지](https://github.com/wooyarich/fstream/releases)** 또는 저장소에 포함된 [`FStream.app.zip`](./FStream.app.zip) / [`FStream.app`](./FStream.app)을 내려받아 바로 실행할 수 있습니다.
- 최초 실행 시 macOS 보안 경고가 뜨는 경우 터미널에서 아래 명령어를 실행하거나 우클릭 → **열기**로 실행하세요:
  ```bash
  xattr -cr FStream.app
  ```

## 주요 기능

- **네이티브 Apple Silicon (`arm64`) 지원**: Rosetta 2 없이 최신 macOS에서 가볍고 빠르게 동작
- **기본 프리셋 방송 제공**:
  - Sky24 음악방송 (`https://sky24.inlive.co.kr/live/listen.pls`)
  - 달빛수채화 음악방송 (`https://mysonsol4.inlive.co.kr/live/listen.pls`)
  - 추억속으로7080 (`https://so0000os.inlive.co.kr/live/listen.pls`)
- **스페이스바 제어 지원**: 앱이 선택되었거나 창이 활성화된 상태에서 `Space` 키로 재생/일시정지 토글 가능
- **편리한 주소 입력**: '간단히 연결하기' 및 '즐겨찾기 추가' 다이얼로그에서 복사/붙여넣기(`⌘C`, `⌘V`, `⌘X`, `⌘A`, `⌘Z`) 키 완벽 지원
- **원본 스킨 완벽 복원**: 원본 `FStream`의 `MyPlugin`에서 추출한 104개의 무손실 스킨 에셋(Blue / Yellow 테마, 재생/일시정지/연결중 파형 애니메이션, 우측 상·하 반원형 메뉴/볼륨 버튼, 부드러운 창 그림자) 탑재
- **강화된 스트리밍 & 메타데이터 파서**:
  - `.pls`, `.m3u`, `.asx`, `.m3u8` 플레이리스트 및 Shoutcast/Icecast(`ICY 200 OK`, `icy-metaint`) 스트림 지원
  - 바이트 단위 `StreamTitle` 추출 및 UTF-8 / EUC-KR / CP949(한글) 자동 인코딩 변환
  - 긴 노래 제목 자동 수평 전광판 스크롤 및 노출 시간 최적화
- **잠자기(Sleep) 복구 후 자동 재연결**:
  - 맥이 잠자기에서 깨어난 후(`NSWorkspace.didWakeNotification`) 및 스트림 무응답 발생 시 자동으로 재연결
  - 모든 소켓·파서·CoreAudio(`AudioFileStream` / `AudioQueue`) 작업을 단일 직렬 큐(`netQueue`)와 세션 ID로 동기화하여 절전 복구 시 스레드 경합 크래시 방지
  - 맥미니 등의 잠자기 해제 시 모니터 EDID 해상도 재협상 동안 창 위치 보존(디바운스 처리)
- **아이콘 표시 위치 선택**: 환경설정 및 우클릭 메뉴에서 **독(Dock)에만 표시** 또는 **상단 메뉴바에만 표시** 선택 가능

## 폴더 구조

```text
.
├── FStream.app               # 빌드된 macOS 앱 번들 (arm64)
├── FStream.app.zip           # 배포용 압축 아카이브
├── build.sh                  # 원클릭 빌드 스크립트 (실행 시 ./FStream.app 생성)
├── Makefile                  # make / make clean / make install 지원
├── .gitignore                # Git 제외 파일 설정
├── src/
│   └── FStreamMain.swift     # 메인 애플리케이션, UI 및 스트리밍/CoreAudio 엔진 소스
└── Resources/
    ├── Info.plist            # 앱 번들 메타데이터 및 ATS 허용 설정
    ├── PkgInfo               # APPLSmFs 패키지 시그니처
    ├── *.icns / *.png        # 앱 아이콘, 플레이리스트 아이콘, 메뉴바 아이콘
    ├── Korean.lproj/         # 한국어 로컬라이제이션 리소스
    ├── English.lproj/        # 영어 로컬라이제이션 리소스
    └── SkinAssets/           # 원본 FStream MyPlugin에서 추출한 104개 무손실 PNG 스킨 에셋
```

## 직접 빌드하는 방법

터미널에서 아래 명령어만 실행하면 현재 폴더에 `FStream.app`이 생성됩니다:

```bash
./build.sh
```

또는 `make`를 사용할 수 있습니다:

```bash
make          # ./FStream.app 빌드
make install  # 빌드 후 /Applications/FStream.app 으로 설치
make clean    # 빌드 결과물 삭제
```

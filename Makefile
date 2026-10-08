# backuppc-vpn + протокол //backuppc — сборка, тесты, отладка.
#
# Продукт — Flutter/Dart: протокол реализован в backuppc_dart/ и встроен в
# приложение (lib/), собирается на всех платформах backuppc-vpn (build_scripts/).
# Go (backuppc/, core/) — эталон для контрактных тестов и нагрузочных
# прогонов. Рабочий процесс: DEVELOPMENT.md; wire-спецификация — в
# репозитории сервера (docs/PROTOCOL.md).
#
# Частые команды:
#   make help        — список всех целей
#   make install     — кросс-платформенная установка dev-окружения
#   make build       — сборка GUI под ТЕКУЩУЮ host OS (auto-detect)
#   make run         — flutter run на текущей host OS
#   make test        — тесты протокола (Dart-библиотека)
#   make e2e-dart    — живой E2E: Go-сервер ↔ Dart-клиент
#   make build-app   — справка сборщиков GUI (все платформы)
#   make build-<os>  — явная сборка под платформу (android/ios/macos/...)

DART ?= dart
FLUTTER ?= flutter
GO ?= go
# PYTHON — как запускать build_scripts/main.py. По умолчанию uv-managed
# venv из build_scripts/.venv (Python 3.12+, ставится install.sh).
# Если uv нет — fallback на системный python3 (требуется 3.12+).
ifeq ($(shell command -v uv 2>/dev/null),)
  PYTHON ?= python3
else
  PYTHON ?= uv run --project build_scripts python
endif

# BUILD_NUMBER — целочисленный номер сборки (uv-style). Дефолт 1 для
# локальных запусков; CI переопределяет через env (GitHub Actions
# использует github.run_number).
BUILD_NUMBER ?= 1

# FLUTTER_ROOT — путь к Flutter SDK (ставится setup_flutter.sh). Если
# задан и flutter не на PATH — используем $FLUTTER_ROOT/bin/flutter.
ifeq ($(shell command -v $(FLUTTER) 2>/dev/null),)
  ifneq ($(FLUTTER_ROOT),)
    FLUTTER := $(FLUTTER_ROOT)/bin/flutter
    DART := $(FLUTTER_ROOT)/bin/dart
  endif
endif

# Pub global binaries (fastforge, etc.) — add to PATH for subprocesses.
# command_line.py already does this for Python subprocess; this helps
# when running commands directly from Makefile (make build-linux).
export PATH := $(HOME)/.pub-cache/bin:$(PATH)

# ─── Host OS auto-detection (for `make build` / `make run`) ────────────
# uname -s returns: Darwin (macOS), Linux, MINGW*/MSYS*/CYGWIN* (Windows).
HOST_OS := $(shell uname -s 2>/dev/null)
ifeq ($(HOST_OS),Darwin)
  AUTOBUILD_TARGET := macos
  AUTORUN_TARGET := macos
else ifeq ($(HOST_OS),Linux)
  AUTOBUILD_TARGET := linux
  AUTORUN_TARGET := linux
else ifneq (,$(findstring MINGW,$(HOST_OS))$(findstring MSYS,$(HOST_OS))$(findstring CYGWIN,$(HOST_OS)))
  AUTOBUILD_TARGET := windows
  AUTORUN_TARGET := windows
else
  $(warning Не удалось определить host OS (uname -s = "$(HOST_OS)"); \
используй явную цель: make build-macos / build-linux / build-windows)
  AUTOBUILD_TARGET := unknown
  AUTORUN_TARGET := unknown
endif

DARTPKG := backuppc_dart
CORE_BIN := core/bin/backuppc-xray
DEPLOY := deploy

.PHONY: help install build run \
	analyze analyze-lib test test-dart test-app e2e-dart \
	build-app build-android build-ios build-macos build-macos-se \
	build-windows build-linux verify-release release-router \
	debug-download debug-upload layer-bench debug-tools \
	test-ref test-ref-race vet-ref fmt-ref fmt-ref-check lint-ref \
	build-core deb ipk e2e-tun e2e-ref e2e-stack loadtest \
	docker-build-core docker-release-router docker-test-ref \
	docker-test-dart docker-e2e-dart \
	docker-build docker-up docker-down docker-stack \
	debug-run clean distclean

help: ## Список целей (make help)
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-18s\033[0m %s\n", $$1, $$2}'

# ─── Кросс-платформенные shortcuts ─────────────────────────────────────

install: ## Кросс-платформенная установка dev-окружения (macOS/Linux/Windows)
	bash install.sh

build: ## Сборка под текущую host OS (auto-detect: macos|linux|windows)
ifeq ($(AUTOBUILD_TARGET),unknown)
	@echo "ERROR: host OS не определена. Используй явную цель:" >&2
	@echo "  make build-macos / build-linux / build-windows / build-android / build-ios" >&2
	@exit 1
else
	@echo "[build] detected host OS = $(HOST_OS) → target = $(AUTOBUILD_TARGET)"
	$(MAKE) build-$(AUTOBUILD_TARGET)
endif

run: ## flutter run на текущей host OS (auto-detect)
ifeq ($(AUTORUN_TARGET),unknown)
	@echo "ERROR: host OS не определена. Используй явную цель: make run-macos / run-linux / run-windows" >&2
	@exit 1
else
	@echo "[run] detected host OS = $(HOST_OS) → target = $(AUTORUN_TARGET)"
	$(FLUTTER) run -d $(AUTORUN_TARGET)
endif

# ─── Продукт: протокол //backuppc (Dart) ──────────────────────────────

analyze-lib: ## dart analyze транспортной библиотеки
	cd $(DARTPKG) && $(DART) analyze

test-dart: ## Тесты протокола: 52 теста backuppc_dart
	cd $(DARTPKG) && $(DART) test

test: analyze-lib test-dart ## Быстрая проверка протокола (анализ + тесты)

analyze: ## flutter analyze всего приложения (все платформы)
	$(FLUTTER) analyze

test-app: ## Полный сьют приложения (flutter test, ~1092 теста)
	$(FLUTTER) test

e2e-dart: ## Живой E2E: Go-сервер ↔ Dart-клиент (DOWN=64 UP=16, МиБ)
	scripts/e2e_dart.sh $(DOWN) $(UP)

# ─── Сборка приложения (все платформы OneXray) ─────────────────────────

build-app: ## Справка сборщиков GUI: платформы и требования
	$(PYTHON) build_scripts/main.py --help

build-android: ## Android (APK)
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray android

build-ios: ## iOS
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray ios

build-macos: ## macOS (Developer ID)
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray macos

build-macos-se: ## Mac App Store
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray macos_se

build-windows: ## Windows (WINDOWS_MODE=exe|msix)
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray windows --windows-mode $(WINDOWS_MODE)

build-linux: ## Linux
	BUILD_NUMBER=$(BUILD_NUMBER) $(PYTHON) build_scripts/main.py OneXray linux

verify-release: ## Проверка релизных артефактов (build_scripts/verify_release.py)
	$(PYTHON) build_scripts/verify_release.py

release-router: ## Ядро для роутеров ASUS/Merlin: arm32-v7a + arm64-v8a
	cd core && mkdir -p bin
	cd core && CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
		$(GO) build -trimpath -ldflags="-s -w" -o bin/xray-linux-arm32-v7a ./cmd/backuppc-xray
	cd core && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		$(GO) build -trimpath -ldflags="-s -w" -o bin/xray-linux-arm64-v8a ./cmd/backuppc-xray
	@ls -lh core/bin/xray-linux-*

# ─── Отладка протокола (Dart) ─────────────────────────────────────────

debug-tools: ## Список отладочных инструментов backuppc_dart/tool
	@ls -1 $(DARTPKG)/tool/

debug-download: ## Скачивание объёма с SHA-256 (CONFIG=client.json DOWN=64)
	cd $(DARTPKG) && $(DART) run tool/debug_download.dart --config $(abspath $(CONFIG)) --down $(DOWN)

debug-upload: ## Отдача объёма в эхо-таргет (CONFIG=client.json UP=16)
	cd $(DARTPKG) && $(DART) run tool/debug_upload.dart --config $(abspath $(CONFIG)) --up $(UP)

layer-bench: ## Микробенчмарк слоёв TLS/H2 (MODE=tls|h2 MIB=256)
	cd $(DARTPKG) && $(DART) run tool/layer_bench.dart --mode $(MODE) --mib $(MIB)

# ─── Go-эталон: контрактные тесты и нагрузка ──────────────────────────

test-ref: ## Тесты Go-эталона (библиотека + ядро)
	cd backuppc && $(GO) test ./... -count=1 -timeout 600s
	cd core && $(GO) test ./... -count=1 -timeout 600s

test-ref-race: ## Гонки данных в Go-эталоне
	cd backuppc && $(GO) test ./internal/... -race -count=1 -timeout 900s

vet-ref: ## go vet по эталону
	cd backuppc && $(GO) vet ./...
	cd core && $(GO) vet ./...

fmt-ref: ## gofmt эталона
	$(GO) fmt ./...
	cd backuppc && $(GO) fmt ./...
	cd core && $(GO) fmt ./...

fmt-ref-check: ## Проверка форматирования эталона (CI)
	@out=$$(gofmt -l backuppc/ core/cmd core/link core/outbound core/preprocess); \
	 if [ -n "$$out" ]; then echo "НЕ ОТФОРМАТИРОВАНО:"; echo "$$out"; exit 1; fi

lint-ref: vet-ref fmt-ref-check ## vet + форматирование эталона

build-core: $(CORE_BIN) ## Безголовое ядро Xray с backuppc-outbound (эталон)

$(CORE_BIN):
	cd core && $(GO) build -trimpath -ldflags="-s -w" -o bin/backuppc-xray ./cmd/backuppc-xray

deb: ## Пакет безголового Linux-клиента -> dist/backuppc-client_*.deb
	GO=$(GO) deploy/linux/build-deb.sh

ipk: ## OpenWrt-пакет backuppc-socks (ARCH=aarch64_cortex-a53|mipsel_24kc|arm_cortex-a7|x86_64)
	GO=$(GO) openwrt/build-ipk.sh $(or $(ARCH),aarch64_cortex-a53)

e2e-tun: ## Живой прогон deb-пакета в Docker: SOCKS + TUN + DNS (SIZE=32)
	GO=$(GO) deploy/linux/e2e-tun.sh

e2e-ref: ## Живой прогон нативного ядра (эталон)
	cd core && ./e2e_native.sh

e2e-stack: ## Полный стек: сервер + безголовое ядро + таргет (без Docker)
	scripts/e2e_stack.sh

loadtest: ## Нагрузка через нативный туннель (SIZE=512M)
	scripts/loadtest.sh

# ─── Docker ───────────────────────────────────────────────────────────

# ── Контейнерная сборка (требование: все сборки — в контейнерах) ──────
# Тулчейны Go/Dart на хосте не нужны; артефакты выгружаются buildx --output.
# Требуется Docker 23+ / buildx (BuildKit).

BUILDX ?= docker buildx
DOCKERFILE_BUILD ?= docker/Dockerfile
DOWN ?= 64
UP ?= 16

docker-build-core: ## Контейнерная сборка ядра -> core/bin/backuppc-xray
	@mkdir -p core/bin
	$(BUILDX) build --target export-core -o $(CURDIR)/core/bin \
		-f $(DOCKERFILE_BUILD) --progress=plain .

docker-release-router: ## Контейнерные бинарники роутеров -> core/bin/xray-linux-*
	@mkdir -p core/bin
	$(BUILDX) build --target export-router -o $(CURDIR)/core/bin \
		-f $(DOCKERFILE_BUILD) --progress=plain .
	@ls -lh core/bin/xray-linux-*

docker-test-ref: ## Контейнерные тесты Go-эталона (backuppc/ + core/)
	$(BUILDX) build --target test-ref -f $(DOCKERFILE_BUILD) --progress=plain .

docker-test-dart: ## Контейнерные тесты протокола (dart test, 52 теста)
	$(BUILDX) build --target test-dart -f $(DOCKERFILE_BUILD) --progress=plain .

docker-e2e-dart: ## Живой e2e в контейнере: Go-сервер <-> Dart-клиент (нужен ../xray-backuppc)
	$(BUILDX) build --target e2e-dart -f docker/Dockerfile.e2e \
		--build-context serverrepo=../xray-backuppc \
		--build-arg DOWN_MB=$(DOWN) --build-arg UP_MB=$(UP) \
		--progress=plain .

# ── Образы рантайма ───────────────────────────────────────────────────

docker-build: ## Образ безголового клиента (backuppc-client)
	docker build -f $(DEPLOY)/Dockerfile -t backuppc-client .

docker-up: ## Одиночный клиент (BACKUPPC_SERVER, BACKUPPC_UUID)
	docker compose -f $(DEPLOY)/docker-compose.yml up -d

docker-down: ## Остановка одиночного клиента
	docker compose -f $(DEPLOY)/docker-compose.yml down

docker-stack: ## Полный стек в Docker: сервер + клиент + таргет
	docker compose -f $(DEPLOY)/docker-compose.stack.yml up

# ─── Отладка ядра (Go-эталон) ─────────────────────────────────────────

debug-run: build-core ## Ядро с pprof и debug-логом (CONF=app.json)
	BACKUPPC_PPROF=127.0.0.1:6060 $(CORE_BIN) run -config $(CONF)

# ─── Чистка ───────────────────────────────────────────────────────────

clean: ## Артефакты сборки
	rm -f $(CORE_BIN) core/bin/*
	rm -rf .tmp-e2e*

distclean: clean ## + контейнеры
	docker compose -f $(DEPLOY)/docker-compose.yml down 2>/dev/null || true
	docker compose -f $(DEPLOY)/docker-compose.stack.yml down 2>/dev/null || true

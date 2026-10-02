# OneXray + протокол //backuppc — сборка, тесты, отладка.
#
# Продукт — Flutter/Dart: протокол реализован в backuppc_dart/ и встроен в
# приложение (lib/), собирается на всех платформах OneXray (build_scripts/).
# Go (backuppc/, core/) — эталон для контрактных тестов и нагрузочных
# прогонов. Рабочий процесс: DEVELOPMENT.md; wire-спецификация — в
# репозитории сервера (docs/PROTOCOL.md).
#
# Частые команды:
#   make help        — список всех целей
#   make test        — тесты протокола (Dart-библиотека)
#   make e2e-dart    — живой E2E: Go-сервер ↔ Dart-клиент
#   make build-app   — сборка GUI (все платформы)

DART ?= dart
FLUTTER ?= flutter
GO ?= go
PYTHON ?= python3

DARTPKG := backuppc_dart
CORE_BIN := core/bin/backuppc-xray
DEPLOY := deploy
LIBXRAY_DIR ?= ../libXray

.PHONY: help \
	analyze analyze-lib test test-dart test-app e2e-dart \
	build-app build-android build-ios build-macos build-macos-se \
	build-windows build-linux verify-release release-router \
	debug-download debug-upload layer-bench debug-tools \
	test-ref test-ref-race vet-ref fmt-ref fmt-ref-check lint-ref \
	build-core bootstrap-libxray patch-libxray e2e-ref e2e-stack loadtest \
	docker-build docker-up docker-down docker-stack \
	debug-run clean distclean

help: ## Список целей (make help)
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-18s\033[0m %s\n", $$1, $$2}'

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
	$(PYTHON) build_scripts/main.py OneXray android

build-ios: ## iOS
	$(PYTHON) build_scripts/main.py OneXray ios

build-macos: ## macOS (Developer ID)
	$(PYTHON) build_scripts/main.py OneXray macos

build-macos-se: ## Mac App Store
	$(PYTHON) build_scripts/main.py OneXray macos_se

build-windows: ## Windows (WINDOWS_MODE=exe|msix)
	$(PYTHON) build_scripts/main.py OneXray windows --windows-mode $(WINDOWS_MODE)

build-linux: ## Linux
	$(PYTHON) build_scripts/main.py OneXray linux

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

bootstrap-libxray: ## Материализует ../libXray из third_party/libXray (bundle, офлайн) + patch.py
	bash core/libxray/bootstrap.sh --dest $(LIBXRAY_DIR)

patch-libxray: ## Патч checkout libXray (LIBXRAY_DIR=../libXray)
	$(PYTHON) core/libxray/patch.py --libxray-dir $(abspath $(LIBXRAY_DIR))

e2e-ref: ## Живой прогон нативного ядра (эталон)
	cd core && ./e2e_native.sh

e2e-stack: ## Полный стек: сервер + безголовое ядро + таргет (без Docker)
	scripts/e2e_stack.sh

loadtest: ## Нагрузка через нативный туннель (SIZE=512M)
	scripts/loadtest.sh

# ─── Docker ───────────────────────────────────────────────────────────

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

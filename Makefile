# xray-backuppc-clent (OneXray + нативный протокол backuppc) — сборка,
# тесты, отладка и развертывание. GUI-сборка приложения — build_scripts/.

GO ?= go
PYTHON ?= python3

# Пути
CORE_BIN  := core/bin/backuppc-xray
CLIENT_GO := backuppc
CORE_GO   := core
DEPLOY    := deploy

.PHONY: help test test-go test-core test-e2e vet fmt fmt-check lint \
        build build-core patch-libxray build-app e2e e2e-stack \
        loadtest docker-build docker-up docker-down docker-stack \
        debug-run clean distclean

help: ## Список целей
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ─── Проверки ────────────────────────────────────────────────────────

test: test-go test-core ## Все Go-тесты (библиотека + ядро)

test-go: ## Тесты библиотеки транспорта (слои 1–2)
	cd $(CLIENT_GO) && $(GO) test ./... -count=1 -timeout 600s

test-core: ## Тесты ядра с нативным outbound (включая E2E с живым Xray)
	cd $(CORE_GO) && $(GO) test ./... -count=1 -timeout 600s

test-race: ## Гонки данных в библиотеке транспорта
	cd $(CLIENT_GO) && $(GO) test ./internal/... -race -count=1 -timeout 900s

vet: ## go vet по обоим модулям
	cd $(CLIENT_GO) && $(GO) vet ./...
	cd $(CORE_GO) && $(GO) vet ./...

fmt: ## gofmt обоих модулей
	$(GO) fmt ./...
	cd $(CLIENT_GO) && $(GO) fmt ./...
	cd $(CORE_GO) && $(GO) fmt ./...

fmt-check: ## проверка форматирования (CI)
	@out=$$(gofmt -l $(CLIENT_GO)/ $(CORE_GO)/cmd $(CORE_GO)/link $(CORE_GO)/outbound $(CORE_GO)/preprocess); \
	 if [ -n "$$out" ]; then echo "НЕ ОТФОРМАТИРОВАНО:"; echo "$$out"; exit 1; fi

lint: vet fmt-check ## vet + форматирование

# ─── Сборка ──────────────────────────────────────────────────────────

build: build-core ## Сборка Go-компонентов

build-core: $(CORE_BIN) ## Безголовое ядро Xray с backuppc-outbound

$(CORE_BIN):
	cd $(CORE_GO) && $(GO) build -trimpath -ldflags="-s -w" -o bin/backuppc-xray ./cmd/backuppc-xray

patch-libxray: ## Пропатчить checkout libXray (нативная интеграция протокола)
	cd $(CORE_GO)/libxray && $(PYTHON) patch.py --libxray-dir $(LIBXRAY_DIR)

build-app: ## GUI-приложение OneXray (Flutter; требует патч libXray)
	$(PYTHON) build_scripts/main.py --help

# ─── E2E и нагрузка ──────────────────────────────────────────────────

e2e: test-e2e ## Живой сквозной прогон нативного протокола

test-e2e:
	cd $(CORE_GO) && ./e2e_native.sh

e2e-stack: ## Полный стек сервер+клиент+таргет локально (Go, без Docker)
	scripts/e2e_stack.sh

loadtest: ## Пропускная способность через нативный туннель (SIZE=512M)
	scripts/loadtest.sh

# ─── Docker ──────────────────────────────────────────────────────────

docker-build: ## Образ безголового клиента (backuppc-client)
	docker build -f $(DEPLOY)/Dockerfile -t backuppc-client .

docker-up: ## Одиночный клиент (BACKUPPC_SERVER, BACKUPPC_UUID)
	docker compose -f $(DEPLOY)/docker-compose.yml up -d

docker-down:
	docker compose -f $(DEPLOY)/docker-compose.yml down

docker-stack: ## Полный стек в Docker: сервер + клиент + таргет
	docker compose -f $(DEPLOY)/docker-compose.stack.yml up

# ─── Отладка ─────────────────────────────────────────────────────────

debug-run: build-core ## Ядро с pprof и логом debug (CONF=app.json)
	BACKUPPC_PPROF=127.0.0.1:6060 $(CORE_BIN) run -config $(CONF)

# ─── Чистка ──────────────────────────────────────────────────────────

clean:
	rm -f $(CORE_BIN) core/bin/*
	rm -rf .tmp-e2e*

distclean: clean
	docker compose -f $(DEPLOY)/docker-compose.yml down 2>/dev/null || true
	docker compose -f $(DEPLOY)/docker-compose.stack.yml down 2>/dev/null || true

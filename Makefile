.PHONY: build test install clean universal serve network-test
build:
	./scripts/build.sh release
test:
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/module-cache" swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security CleanmossChecks
install:
	./scripts/install.sh
clean:
	swift package clean
universal:
	./scripts/build.sh release universal
serve:
	./scripts/serve-tailnet.sh
network-test:
	PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/tests/test_distribution.py

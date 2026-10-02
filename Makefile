.PHONY: models build run test

models:
	zsh Scripts/download-models.sh

build:
	zsh Scripts/build-app.sh

run: build
	open dist/Mitschrift.app

test:
	zsh Scripts/test-core.sh

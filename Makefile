.PHONY: models build run

models:
	zsh Scripts/download-models.sh

build:
	zsh Scripts/build-app.sh

run: build
	open dist/Mitschrift.app

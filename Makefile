.PHONY: all build clean install

all: build

build:
	@./build.sh

clean:
	@rm -rf FStream.app

install: build
	@cp -R FStream.app /Applications/
	@echo "Installed to /Applications/FStream.app"

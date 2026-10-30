PLUGIN_ID  := $(shell python3 -c "import json; print(json.load(open('manifest.json'))['id'])")
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)

.PHONY: validate test demo install

validate:
	omarchy plugin validate .

test:
	node --test tests/
	python3 -m unittest discover tests

demo:
	python3 bin/hevy-sync.py --demo | python3 -m json.tool

install:
	rsync -a --delete \
		--exclude .git \
		--exclude tests \
		--exclude preview.png \
		./ $(PLUGIN_DIR)/
	@echo "Installed to $(PLUGIN_DIR)"

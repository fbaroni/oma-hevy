PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/dev.fede.oma-hevy

.PHONY: validate test demo install

validate:
	omarchy plugin validate .

test:
	node --test tests/

demo:
	python3 bin/hevy-sync.py --demo | python3 -m json.tool

install:
	rsync -a --delete \
		--exclude .git \
		--exclude tests \
		--exclude preview.png \
		./ $(PLUGIN_DIR)/
	@echo "Installed to $(PLUGIN_DIR)"

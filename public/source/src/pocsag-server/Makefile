# ============================================================================
# Makefile - pocsag-server
# ============================================================================
BASE   := /opt/pocsag-server
DB     := $(BASE)/database/pocsag.db

.PHONY: help install uninstall update test init-db reload-asterisk status logs

help:
	@echo "targets: install uninstall update test init-db reload-asterisk status logs"

install:
	sudo bash install.sh

uninstall:
	sudo bash uninstall.sh

update:
	sudo bash update.sh

init-db:
	python3 database/db_manager.py init

reload-asterisk:
	asterisk -rx "dialplan reload" || true
	asterisk -rx "pjsip reload" || true

test:
	bash tests/run_tests.sh

status:
	bash scripts/healthcheck.sh

logs:
	tail -n 50 $(BASE)/logs/pocsag.log 2>/dev/null || echo "sin logs aún"
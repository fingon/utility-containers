ENGINE ?= podman
IMAGE_PREFIX ?= localhost/utility-containers

NFCAPD_CONTEXT ?= nfcapd
NFCAPD_CONTAINERFILE ?= $(NFCAPD_CONTEXT)/Containerfile
NFCAPD_IMAGE ?= $(IMAGE_PREFIX)/nfcapd:alpine

SAMBA_CONTEXT ?= samba
SAMBA_CONTAINERFILE ?= $(SAMBA_CONTEXT)/Containerfile
SAMBA_IMAGE ?= $(IMAGE_PREFIX)/samba:24.04

.DEFAULT_GOAL := help

.PHONY: build build-nfcapd build-samba test test-nfcapd test-samba lint help

build: build-nfcapd build-samba

build-nfcapd:
	$(ENGINE) build --file $(NFCAPD_CONTAINERFILE) --tag $(NFCAPD_IMAGE) $(NFCAPD_CONTEXT)

build-samba:
	$(ENGINE) build --file $(SAMBA_CONTAINERFILE) --tag $(SAMBA_IMAGE) $(SAMBA_CONTEXT)

test: test-nfcapd test-samba

test-nfcapd: build-nfcapd
	ENGINE='$(ENGINE)' IMAGE='$(NFCAPD_IMAGE)' ./$(NFCAPD_CONTEXT)/test-integration.sh

test-samba: build-samba
	ENGINE='$(ENGINE)' IMAGE='$(SAMBA_IMAGE)' ./$(SAMBA_CONTEXT)/test-integration.sh

lint:
	prek run --all-files

help:
	@printf '%s\n' \
		'Targets:' \
		'  build        Build both container images' \
		'  build-nfcapd Build the nfcapd image' \
		'  build-samba  Build the Samba image' \
		'  test         Build and run both integration test suites' \
		'  test-nfcapd  Build and test the nfcapd image' \
		'  test-samba   Build and test the Samba image' \
		'  lint         Run all prek checks' \
		'  help         Show this help' \
		'' \
		'Variables:' \
		'  ENGINE=$(ENGINE)' \
		'  IMAGE_PREFIX=$(IMAGE_PREFIX)' \
		'  NFCAPD_IMAGE=$(NFCAPD_IMAGE)' \
		'  SAMBA_IMAGE=$(SAMBA_IMAGE)'

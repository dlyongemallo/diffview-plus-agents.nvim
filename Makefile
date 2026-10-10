TEST_PATH := $(if $(TEST_PATH),$(TEST_PATH),lua/diffview-plus-agents/tests/)
export TEST_PATH

# Run the test suite:
#   make test
#
# Or a single spec:
#   TEST_PATH=lua/diffview-plus-agents/tests/sidekick_provider_spec.lua make test
#
# Plenary is fetched on first run into .tests/site/pack/deps/start/.
.PHONY: test
test:
	nvim --headless -i NONE -n -u scripts/test_init.lua -c \
		"PlenaryBustedDirectory $(TEST_PATH) { minimal_init = './scripts/test_init.lua' }"

.PHONY: clean
clean:
	rm -rf .tests

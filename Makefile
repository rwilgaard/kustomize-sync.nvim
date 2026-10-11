.PHONY: test deps

# mini.test runs the suite; nui.nvim is the plugin's own dependency.
deps: deps/mini.test deps/nui.nvim

deps/mini.test:
	git clone --depth 1 https://github.com/nvim-mini/mini.test $@

deps/nui.nvim:
	git clone --depth 1 https://github.com/MunifTanjim/nui.nvim $@

test: deps
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run()"

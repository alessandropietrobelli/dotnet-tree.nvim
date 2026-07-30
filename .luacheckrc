std = "lua51"
cache = true

globals = {
  "vim",
}

-- neo-tree passes a lot of context around; unused arguments in source
-- callbacks are part of the API contract, not mistakes.
unused_args = false

max_line_length = 120

exclude_files = {
  "deps/",
}

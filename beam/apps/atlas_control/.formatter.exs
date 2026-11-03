# The spec DSL reads without parentheses, in the catalogue and in tests.
spec_dsl = [version: 1, defblock: 2, defmodel: 2, field: 2, field: 3]

[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "../../../spec/control/*.ex"
  ],
  locals_without_parens: spec_dsl,
  export: [locals_without_parens: spec_dsl]
]

# The schema DSL reads without parentheses, in a contract and in tests.
schema_dsl = [version: 1, defblock: 2, defmodel: 2, defmarkup: 2, field: 2, field: 3]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: schema_dsl,
  export: [locals_without_parens: schema_dsl]
]

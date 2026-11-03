import Config

# What `mix atlas.gen` generates from this contract, and where.
config :atlas_spec,
  contract: AtlasContract.Blocks,
  targets: [json: "../targets/json"],
  # Headers name the contract file from the repository's root.
  root: "../.."

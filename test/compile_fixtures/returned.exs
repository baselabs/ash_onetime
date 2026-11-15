# The values the matrix fixture's generic actions return. Only the matrix runner's fresh
# VM requires this file: resources defined in the test VM after protocol consolidation
# would carry Inspect implementations that have no effect.

# The persisted resource another resource's generic action returns as a `:struct`
# `instance_of`: response fields are validated against it and executing_only names must
# not name its fields (V2).
defmodule AshOnetime.CompileFixture.Returned do
  use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

  postgres do
    table "compile_fixture_returned"
    repo AshOnetime.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true
    # Public on the action's resource, private here: a projection valid on the action's
    # resource is refused on the returned one.
    attribute :amount, :integer, public?: false
  end

  calculations do
    calculate :label, :string, expr("label"), public?: true
  end
end

# An embedded resource a generic action returns as a value, bare or as a `:struct`
# `instance_of`. It has no record source, so it takes no response fields; it is stored
# whole, so executing_only names must not name its fields either (V2).
defmodule AshOnetime.CompileFixture.Stamp do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :token, :string, public?: true
  end
end

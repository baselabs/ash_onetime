defmodule AshOnetime.Test.Support.BoundaryDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.Support.BoundaryResource
  end
end

defmodule AshOnetime.Test.Support.BoundaryResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.Support.BoundaryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "boundary_examples"
    repo AshOnetime.Test.Repo
  end

  context_boundary do
    fact_table("boundary_example_facts")
  end

  attributes do
    uuid_primary_key :id
    attribute :context_tag, :string, public?: true, allow_nil?: false
    attribute :amount, :integer, public?: true
  end

  actions do
    create :record do
      accept [:context_tag, :amount]

      argument :context_cutoff, :integer, allow_nil?: false
      argument :context_facts, {:array, :map}, allow_nil?: false
      argument :context_tenant, :string, allow_nil?: false

      change {AshOnetime.Boundary.Change,
              query: {:all, [tag: {:argument, :context_tag}, type: "record"]},
              cutoff: {:argument, :context_cutoff},
              facts: {:argument, :context_facts},
              tenant: {:argument, :context_tenant}}
    end
  end
end

defmodule AshOnetime.Test.Support.UnscopedBoundaryResource do
  @moduledoc false

  # No context_boundary section: Boundary calls against it fail closed with
  # :invalid_request rather than falling back to any default fact table.
  use Ash.Resource,
    domain: nil,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "boundary_examples"
    repo AshOnetime.Test.Repo
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

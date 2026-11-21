defmodule AshOnetime.Test.ResultExamples.Receipt do
  @moduledoc false

  # The record a generic action of `Account` returns. Its fields differ from the action's
  # resource, so a response projection is valid on exactly one of the two (§2.7.6).
  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true, allow_nil?: false
    attribute :code, :string, public?: false
  end
end

defmodule AshOnetime.Test.ResultExamples.Stamp do
  @moduledoc false

  # An embedded resource: the one resource module Ash takes as a bare return type. Its
  # record is a value, stored through the typed path, never a returned record (§2.7.6).
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :token, :string, public?: true, allow_nil?: false
  end
end

defmodule AshOnetime.Test.ResultExamples.Account do
  @moduledoc false

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :amount, :decimal, public?: true
    attribute :sentinel_private, :string, public?: false
    attribute :secret, :string, public?: true, sensitive?: true
  end

  relationships do
    belongs_to :parent, __MODULE__, public?: true
  end

  actions do
    create :create_account do
      accept [:name, :amount]
    end

    update :update_account do
      accept [:name, :amount]
    end

    destroy :destroy_account

    action :decimal_result, :decimal do
      constraints max: 100
    end

    action :uuid_result, :uuid
    action :datetime_result, :utc_datetime_usec
    action :array_result, {:array, :integer}
    action :map_result, :map

    # rule:return-contract
    action :nullable_result, :string do
      allow_nil? true
    end

    action :nothing

    action :receipt_struct, :struct do
      constraints instance_of: AshOnetime.Test.ResultExamples.Receipt
    end

    action :maybe_receipt, :struct do
      constraints instance_of: AshOnetime.Test.ResultExamples.Receipt
      allow_nil? true
    end

    action :stamp, AshOnetime.Test.ResultExamples.Stamp

    action :stamp_struct, :struct do
      constraints instance_of: AshOnetime.Test.ResultExamples.Stamp
    end
  end
end

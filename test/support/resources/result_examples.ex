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

    action :nullable_result, :string do
      allow_nil? true
    end

    action :nothing
  end
end

defmodule AshOnetime.Test.RollbackClock do
  @moduledoc false

  alias AshOnetime.Test.Repo

  def now, do: Repo.rollback(:clock_abort)
end

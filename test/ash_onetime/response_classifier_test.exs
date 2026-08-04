defmodule AshOnetime.ResponseClassifierTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Error
  alias AshOnetime.ResponseClassifier
  alias AshOnetime.Test.{InvalidClassifier, RaisingClassifier, RejectClassifier}
  alias AshOnetime.Test.{RollbackClassifier, StoreClassifier}

  test "accepts only the three closed outcomes" do
    assert ResponseClassifier.classify(StoreClassifier, :value, %{}) == {:store, :value}
    assert ResponseClassifier.classify(RejectClassifier, :reason, %{}) == {:reject, :reason}
    assert ResponseClassifier.classify(RollbackClassifier, :reason, %{}) == {:rollback, :reason}
  end

  test "malformed output and boundary failures are value-free typed errors" do
    assert {:error, %Error{code: :response_classifier_invalid, details: %{}}} =
             ResponseClassifier.classify(InvalidClassifier, :secret, %{})

    assert {:error, %Error{code: :response_classifier_failed, details: %{}}} =
             ResponseClassifier.classify(RaisingClassifier, :secret, %{})
  end
end

defmodule AshOnetime.ResponseClassifierTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Error
  alias AshOnetime.ResponseClassifier

  alias AshOnetime.Test.{
    ExitingClassifier,
    InvalidClassifier,
    RaisingClassifier,
    RejectClassifier
  }

  alias AshOnetime.Test.{RollbackClassifier, StoreClassifier, ThrowingClassifier}

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

  test "a throwing or exiting classifier fails closed without leaking the value" do
    # Exercises the catch arm (kind ∈ [:throw, :exit]), distinct from the rescue arm.
    assert {:error, %Error{code: :response_classifier_failed, details: %{}}} =
             ResponseClassifier.classify(ThrowingClassifier, :secret, %{})

    assert {:error, %Error{code: :response_classifier_failed, details: %{}}} =
             ResponseClassifier.classify(ExitingClassifier, :secret, %{})
  end

  @tag :classifier_context_guard_mutation
  test "a non-map context fails closed before the classifier is invoked" do
    assert {:error, %Error{code: :response_classifier_invalid, details: %{}}} =
             ResponseClassifier.classify(StoreClassifier, :secret, :not_a_map)
  end

  test "a non-atom classifier fails closed" do
    assert {:error, %Error{code: :response_classifier_invalid, details: %{}}} =
             ResponseClassifier.classify("not-a-module", :secret, %{})
  end
end

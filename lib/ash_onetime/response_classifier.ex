defmodule AshOnetime.ResponseClassifier do
  @moduledoc """
  Normalizes application response classification at the persistence boundary.
  """

  alias AshOnetime.Error

  @callback classify(term(), map()) ::
              {:store, term()} | {:reject, term()} | {:rollback, term()}

  @spec classify(module(), term(), map()) ::
          {:store, term()} | {:reject, term()} | {:rollback, term()} | {:error, Error.t()}
  def classify(classifier, value, context) when is_atom(classifier) and is_map(context) do
    case classifier.classify(value, context) do
      {outcome, classified} when outcome in [:store, :reject, :rollback] ->
        {outcome, classified}

      _other ->
        {:error,
         Error.new(
           :response_classifier_invalid,
           "response classifier returned an invalid outcome"
         )}
    end
  rescue
    _exception ->
      {:error, Error.new(:response_classifier_failed, "response classifier failed")}
  catch
    _kind, _reason ->
      {:error, Error.new(:response_classifier_failed, "response classifier failed")}
  end

  def classify(_classifier, _value, _context) do
    {:error, Error.new(:response_classifier_invalid, "response classifier is invalid")}
  end
end

defmodule AshOnetime.ErrorTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Error

  describe "Splode integration (ARCH-1)" do
    @tag :error_splode_membership_mutation
    test "AshOnetime.Error is recognized as an Ash error" do
      error = Error.new(:nonce_already_used, "nonce was already used")

      # RED today: AshOnetime.Error is a bare defexception, so ash_error? is false.
      # GREEN: use Splode.Error makes splode_error?/0 true, so Ash.Error.ash_error?/1 true.
      assert Ash.Error.ash_error?(error) == true
    end

    test "the typed code survives Ash.Error.to_ash_error/1 (class :invalid)" do
      error = Error.new(:nonce_already_used, "nonce was already used")

      wrapped = Ash.Error.to_ash_error(error)

      # A single Splode leaf error is returned directly by to_ash_error (not wrapped in a
      # class) — Splode returns the leaf when there is exactly one non-class error. Either
      # way the class is :invalid and the code survives. RED today: it became an
      # Ash.Error.Unknown.UnknownError with class :unknown and no :code field (code lost).
      assert wrapped.class == :invalid

      # The leaf carrying the code is either the wrapped result itself (single-error case)
      # or the single entry in .errors. Error.code/1 recovers it from either shape.
      assert Error.code(wrapped) == :nonce_already_used
    end

    test "a single error returned through the Ash pipeline keeps its code" do
      error = Error.new(:key_reused_with_different_request, "key was reused with a different request")

      wrapped = Ash.Error.to_ash_error(error)

      # The public accessor recovers the code from whatever Ash hands the caller — whether
      # the leaf is returned directly or wrapped in a class. RED today: code lost entirely.
      assert Error.code(wrapped) == :key_reused_with_different_request
    end

    test "multiple errors are wrapped in Ash.Error.Invalid and each code survives" do
      e1 = Error.new(:nonce_already_used, "nonce was already used")
      e2 = Error.new(:request_in_progress, "request is already processing")

      wrapped = Ash.Error.to_ash_error([e1, e2])

      # Multiple leaves collapse into the class wrapper.
      assert wrapped.class == :invalid
      assert %{errors: leaves} = wrapped
      codes = Enum.map(leaves, &Error.code/1)
      assert :nonce_already_used in codes
      assert :request_in_progress in codes
    end
  end

  describe "Error.code/1 accessor" do
    test "returns the code from a leaf AshOnetime.Error" do
      error = Error.new(:request_in_progress, "request is already processing", %{claim_id: "abc"})
      assert Error.code(error) == :request_in_progress
    end

    test "returns the code from the wrapped class error" do
      error = Error.new(:nonce_already_used, "nonce was already used")
      wrapped = Ash.Error.to_ash_error(error)
      assert Error.code(wrapped) == :nonce_already_used
    end

    test "returns nil for a non-AshOnetime error" do
      assert Error.code(%ArgumentError{message: "nope"}) == nil
      assert Error.code(:not_even_an_exception) == nil
    end
  end

  describe "struct preservation" do
    test "user fields (code/message/details) are preserved verbatim" do
      details = %{claim_id: Ecto.UUID.generate(), strategy: :one_time_nonce}
      error = Error.new(:verification_timeout, "verification timed out", details)

      assert error.code == :verification_timeout
      assert error.message == "verification timed out"
      assert error.details == details
    end

    test "pattern matching on %AshOnetime.Error{code: :x} still works" do
      error = Error.new(:duplicate_map_key, "duplicate")

      # The code-specific match sites (token.ex:171,174) must survive Splode membership.
      result =
        case error do
          %Error{code: :duplicate_map_key} -> :matched
          _other -> :missed
        end

      assert result == :matched
    end

    test "class field is :invalid (leaf error, not a class wrapper)" do
      error = Error.new(:store_invariant, "invariant violated")

      assert error.class == :invalid
      assert Error.splode_error?() == true
      assert Error.error_class?() == false
    end
  end
end

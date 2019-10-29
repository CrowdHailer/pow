defmodule Pow.Store.CredentialsCacheTest do
  use ExUnit.Case
  doctest Pow.Store.CredentialsCache

  alias Pow.Store.{Backend.EtsCache, CredentialsCache}
  alias Pow.Test.Ecto.Users.{User, UsernameUser}
  alias Pow.Test.EtsCacheMock

  @config [backend: EtsCacheMock]
  @backend_config [namespace: "credentials"]

  setup context do
    EtsCacheMock.init()

    {:ok, context}
  end

  test "stores sessions" do
    user_1 = %User{id: 1}
    user_2 = %User{id: 2}
    user_3 = %UsernameUser{id: 1}

    CredentialsCache.put(@config, "key_1", {user_1, a: 1})
    CredentialsCache.put(@config, "key_2", {user_1, a: 2})
    CredentialsCache.put(@config, "key_3", {user_2, a: 3})
    CredentialsCache.put(@config, "key_4", {user_3, a: 4})

    assert CredentialsCache.get(@config, "key_1") == {user_1, a: 1}
    assert CredentialsCache.get(@config, "key_2") == {user_1, a: 2}
    assert CredentialsCache.get(@config, "key_3") == {user_2, a: 3}
    assert CredentialsCache.get(@config, "key_4") == {user_3, a: 4}

    assert Enum.sort(CredentialsCache.users(@config, User)) == [user_1, user_2]
    assert CredentialsCache.users(@config, UsernameUser) == [user_3]

    assert CredentialsCache.sessions(@config, user_1) == ["key_1", "key_2"]
    assert CredentialsCache.sessions(@config, user_2) == ["key_3"]
    assert CredentialsCache.sessions(@config, user_3) == ["key_4"]

    assert EtsCacheMock.get(@backend_config, "key_1") == {[User, :user, 1], a: 1}
    assert EtsCacheMock.get(@backend_config, [User, :user, 1]) == user_1
    assert EtsCacheMock.get(@backend_config, [User, :user, 1, :session, "key_1"])

    CredentialsCache.put(@config, "key_2", {%{user_1 | email: :updated}, a: 5})
    assert CredentialsCache.get(@config, "key_1") == {%{user_1 | email: :updated}, a: 1}

    assert CredentialsCache.delete(@config, "key_1") == :ok
    assert CredentialsCache.get(@config, "key_1") == :not_found
    assert CredentialsCache.sessions(@config, user_1) == ["key_2"]

    assert EtsCacheMock.get(@backend_config, "key_1") == :not_found
    assert EtsCacheMock.get(@backend_config, [User, :user, 1]) == %{user_1 | email: :updated}
    assert EtsCacheMock.get(@backend_config, [User, :user, 1, :session, "key_1"]) == :not_found

    assert CredentialsCache.delete(@config, "key_2") == :ok
    assert CredentialsCache.sessions(@config, user_1) == []

    assert EtsCacheMock.get(@backend_config, "key_1") == :not_found
    assert EtsCacheMock.get(@backend_config, [User, :user, 1]) == %{user_1 | email: :updated}
    assert EtsCacheMock.get(@backend_config, [User, :user, 1, :session, "key_1"]) == :not_found
  end

  test "put/3 invalidates sessions with identical fingerprint" do
    user = %User{id: 1}

    CredentialsCache.put(@config, "key_1", {user, fingerprint: 1})
    CredentialsCache.put(@config, "key_2", {user, fingerprint: 2})

    assert CredentialsCache.get(@config, "key_1") == {user, fingerprint: 1}

    CredentialsCache.put(@config, "key_3", {user, fingerprint: 1})

    assert CredentialsCache.get(@config, "key_1") == :not_found
    assert CredentialsCache.get(@config, "key_2") == {user, fingerprint: 2}
    assert CredentialsCache.get(@config, "key_3") == {user, fingerprint: 1}
  end

  test "raises for nil primary key value" do
    user_1 = %User{id: nil}

    assert_raise RuntimeError, "Primary key value for key `:id` in Pow.Test.Ecto.Users.User can't be `nil`", fn ->
      CredentialsCache.put(@config, "key_1", {user_1, a: 1})
    end
  end

  defmodule NoPrimaryFieldUser do
    use Ecto.Schema

    @primary_key false
    schema "users" do
      timestamps()
    end
  end

  defmodule CompositePrimaryFieldsUser do
    use Ecto.Schema

    @primary_key false
    schema "users" do
      field :some_id, :integer, primary_key: true
      field :another_id, :integer, primary_key: true

      timestamps()
    end
  end

  test "handles custom primary fields" do
    assert_raise RuntimeError, "No primary keys found for Pow.Store.CredentialsCacheTest.NoPrimaryFieldUser", fn ->
      CredentialsCache.put(@config, "key_1", {%NoPrimaryFieldUser{}, a: 1})
    end

    assert_raise RuntimeError, "Primary key value for key `:another_id` in Pow.Store.CredentialsCacheTest.CompositePrimaryFieldsUser can't be `nil`", fn ->
      CredentialsCache.put(@config, "key_1", {%CompositePrimaryFieldsUser{}, a: 1})
    end

    user = %CompositePrimaryFieldsUser{some_id: 1, another_id: 2}

    CredentialsCache.put(@config, "key_1", {user, a: 1})

    assert CredentialsCache.users(@config, CompositePrimaryFieldsUser) == [user]
  end

  defmodule NonEctoUser do
    defstruct [:id]
  end

  test "handles non-ecto user struct" do
    assert_raise RuntimeError, "Primary key value for key `:id` in Pow.Store.CredentialsCacheTest.NonEctoUser can't be `nil`", fn ->
      CredentialsCache.put(@config, "key_1", {%NonEctoUser{}, a: 1})
    end

    user = %NonEctoUser{id: 1}

    assert CredentialsCache.put(@config, "key_1", {user, a: 1})

    assert CredentialsCache.users(@config, NonEctoUser) == [user]
  end

  describe "with EtsCache backend" do
    setup do
      start_supervised!({EtsCache, []})

      :ok
    end

    test "handles purged values" do
      user_1 = %User{id: 1}
      config = [backend: EtsCache]

      CredentialsCache.put(config ++ [ttl: 150], "key_1", {user_1, a: 1})
      :timer.sleep(50)
      CredentialsCache.put(config ++ [ttl: 200], "key_2", {user_1, a: 2})
      :timer.sleep(50)

      assert CredentialsCache.get(config, "key_1") == {user_1, a: 1}
      assert CredentialsCache.get(config, "key_2") == {user_1, a: 2}
      assert CredentialsCache.sessions(config, user_1) == ["key_1", "key_2"]

      :timer.sleep(50)
      assert CredentialsCache.get(config, "key_1") == :not_found
      assert CredentialsCache.get(config, "key_2") == {user_1, a: 2}
      assert CredentialsCache.sessions(config, user_1) == ["key_2"]

      CredentialsCache.put(config ++ [ttl: 100], "key_2", {user_1, a: 3})
      :timer.sleep(50)
      assert CredentialsCache.sessions(config, user_1) == ["key_2"]

      :timer.sleep(50)
      assert CredentialsCache.get(config, "key_1") == :not_found
      assert CredentialsCache.get(config, "key_2") == :not_found
      assert CredentialsCache.sessions(config, user_1) == []
      assert EtsCache.get(config, "#{Macro.underscore(User)}_sessions_1") == :not_found
    end
  end
end

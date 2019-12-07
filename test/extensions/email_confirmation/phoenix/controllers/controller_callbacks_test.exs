defmodule PowEmailConfirmation.Phoenix.ControllerCallbacksTest do
  use PowEmailConfirmation.TestWeb.Phoenix.ConnCase

  alias Pow.{Ecto.Schema.Password, Plug}
  alias PowEmailConfirmation.Test.Users.User

  @password "secret1234"

  describe "Pow.Phoenix.SessionController.create/2" do
    @valid_params %{"email" => "test@example.com", "password" => @password}

    test "when current email unconfirmed", %{conn: conn} do
      conn = post conn, Routes.pow_session_path(conn, :create, %{"user" => @valid_params})

      assert get_flash(conn, :error) == "You'll need to confirm your e-mail before you can sign in. An e-mail confirmation link has been sent to you."
      assert redirected_to(conn) == "/after_signed_in"

      refute Plug.current_user(conn)

      assert_received {:mail_mock, mail}
      assert token = mail.user.email_confirmation_token
      refute mail.user.email_confirmed_at
      assert mail.html =~ "<a href=\"http://localhost/confirm-email/#{token}\">"
      assert mail.user.email == "test@example.com"
    end

    test "when current email has been confirmed", %{conn: conn} do
      conn = post conn, Routes.pow_session_path(conn, :create, %{"user" => Map.put(@valid_params, "email", "confirmed-email@example.com")})

      assert get_flash(conn, :info) == "signed_in"
      assert redirected_to(conn) == "/after_signed_in"
    end

    test "when current email confirmed and has unconfirmed changed email", %{conn: conn} do
      conn = post conn, Routes.pow_session_path(conn, :create, %{"user" => Map.put(@valid_params, "email", "with-unconfirmed-changed-email@example.com")})

      assert %{id: 1} = Plug.current_user(conn)

      refute_received {:mail_mock, _mail}
    end
  end

  describe "Pow.Phoenix.RegistrationController.create/2" do
    @valid_params %{"user" => %{"email" => "test@example.com", "password" => @password, "confirm_password" => @password}}

    test "with valid params", %{conn: conn} do
      conn = post conn, Routes.pow_registration_path(conn, :create, @valid_params)

      assert get_flash(conn, :error) == "You'll need to confirm your e-mail before you can sign in. An e-mail confirmation link has been sent to you."
      assert redirected_to(conn) == "/after_registration"

      refute Plug.current_user(conn)

      assert_received {:mail_mock, mail}
      assert token = mail.user.email_confirmation_token
      refute mail.user.email_confirmed_at
      assert mail.html =~ "<a href=\"http://localhost/confirm-email/#{token}\">"
      assert mail.user.email == "test@example.com"
    end

    @email_taken_invalid_params %{"user" => %{"email" => "taken@example.com", "password" => @password, "confirm_password" => "s"}}
    test "with invalid params and email taken", %{conn: conn} do
      conn = post conn, Routes.pow_registration_path(conn, :create, @email_taken_invalid_params)

      assert html = html_response(conn, 200)
      refute html =~ "<span class=\"help-block\">has already been taken</span>"
      assert html =~ "<span class=\"help-block\">not same as password</span>"
    end

    @email_taken_valid_params %{"user" => %{"email" => "taken@example.com", "password" => @password, "confirm_password" => @password}}
    test "with valid params and email taken", %{conn: conn} do
      conn = post conn, Routes.pow_registration_path(conn, :create, @email_taken_valid_params)

      assert get_flash(conn, :error) == "You'll need to confirm your e-mail before you can sign in. An e-mail confirmation link has been sent to you."
      assert redirected_to(conn) == "/after_registration"

      refute Plug.current_user(conn)

      refute_received {:mail_mock, _mail}
    end
  end

  describe "Pow.Phoenix.RegistrationController.update/2" do
    @token               "token"
    @params              %{"email" => "test@example.com", "current_password" => @password}
    @change_email_params %{"email" => "new@example.com", "current_password" => @password}
    @user                %User{id: 1, email: "test@example.com", password_hash: Password.pbkdf2_hash(@password), email_confirmation_token: @token}

    setup %{conn: conn} do
      user = Ecto.put_meta(@user, state: :loaded)
      conn = Plug.assign_current_user(conn, user, [])

      {:ok, conn: conn}
    end

    test "when email changes", %{conn: conn} do
      conn = put conn, Routes.pow_registration_path(conn, :update, %{"user" => @change_email_params})
      assert %{id: 1, email: "test@example.com", email_confirmation_token: new_token} = Plug.current_user(conn)

      assert get_flash(conn, :error) == "You'll need to confirm the e-mail before it's updated. An e-mail confirmation link has been sent to you."
      assert get_flash(conn, :info) == "Your account has been updated."
      assert new_token != @token

      assert_received {:mail_mock, mail}
      assert mail.subject == "Confirm your email address"
      assert mail.text =~ "\nhttp://localhost/confirm-email/#{new_token}\n"
      assert mail.html =~ "<a href=\"http://localhost/confirm-email/#{new_token}\">"
      assert mail.user.email == "new@example.com"
    end

    test "when email hasn't changed", %{conn: conn} do
      conn = put conn, Routes.pow_registration_path(conn, :update, %{"user" => @params})

      assert get_flash(conn, :info) == "Your account has been updated."
      assert %{id: 1, unconfirmed_email: nil, email_confirmation_token: nil} = Plug.current_user(conn)

      refute_received {:mail_mock, _mail}
    end
  end

  alias PowEmailConfirmation.PowInvitation.TestWeb.Phoenix.Endpoint, as: PowInvitationEndpoint
  alias PowEmailConfirmation.PowInvitation.TestWeb.Phoenix.Router.Helpers, as: PowInvitationRoutes

  defp put_invitation(conn, path) do
    Phoenix.ConnTest.dispatch(conn, PowInvitationEndpoint, :put, path)
  end

  describe "PowInvitation.Phoenix.InvitationController.update/2" do
    @token               "token"
    @params              %{"email" => "test@example.com", "password" => @password, "confirm_password" => @password}
    @change_email_params %{"email" => "new@example.com", "password" => @password, "confirm_password" => @password}

    test "when email changes", %{conn: conn} do
      conn = put_invitation conn, PowInvitationRoutes.pow_invitation_invitation_path(conn, :update, @token, %{"user" => @change_email_params})

      assert %{id: 1, email_confirmation_token: new_token} = Plug.current_user(conn)
      refute is_nil(new_token)

      assert_received {:mail_mock, _mail}
    end

    test "when email hasn't changed", %{conn: conn} do
      conn = put_invitation conn, PowInvitationRoutes.pow_invitation_invitation_path(conn, :update, @token, %{"user" => @params})

      assert %{id: 1, email_confirmation_token: nil} = Plug.current_user(conn)

      refute_received {:mail_mock, _mail}
    end
  end
end

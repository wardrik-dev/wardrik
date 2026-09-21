defmodule TarsOAuth.TokenTest do
  use ExUnit.Case, async: true

  alias TarsOAuth.Token

  describe "from_response/1" do
    test "reads a token endpoint's answer" do
      assert {:ok, token} =
               Token.from_response(%{
                 "access_token" => "at",
                 "refresh_token" => "rt",
                 "expires_in" => 60,
                 "scope" => "repo",
                 "token_type" => "bearer"
               })

      assert token.access_token == "at"
      assert token.refresh_token == "rt"
      assert token.scope == "repo"
      assert token.type == "bearer"
    end

    test "takes an expiry sent as a string, as some servers do" do
      assert {:ok, token} =
               Token.from_response(%{"access_token" => "at", "expires_in" => "3600"})

      assert token.expires_at > System.system_time(:second)
    end

    test "an expiry it cannot read means no expiry" do
      assert {:ok, %Token{expires_at: nil}} =
               Token.from_response(%{"access_token" => "at", "expires_in" => "soon"})
    end

    test "defaults the token type where a server sends none" do
      assert {:ok, %Token{type: "Bearer"}} = Token.from_response(%{"access_token" => "at"})
    end

    test "a refusal names itself" do
      answer = %{"error" => "invalid_grant", "error_description" => "expired"}

      assert {:error, {:token_refused, "invalid_grant", "expired"}} = Token.from_response(answer)
    end

    test "anything else is unreadable rather than a crash" do
      assert {:error, {:token_unreadable, _body}} = Token.from_response(%{"nothing" => true})
    end
  end

  describe "decode/1" do
    test "refuses something that is not a token" do
      assert {:error, {:token_unreadable, _other}} = Token.decode(~s({"no":"token"}))
    end

    test "refuses something that is not JSON" do
      assert {:error, _reason} = Token.decode("not json")
    end
  end

  describe "renewable?/1 and renewed/2" do
    test "a token with no refresh token cannot be renewed" do
      {:ok, token} = Token.from_response(%{"access_token" => "at"})

      refute Token.renewable?(token)
    end

    test "a renewal that brings its own refresh token keeps it" do
      {:ok, first} = Token.from_response(%{"access_token" => "a", "refresh_token" => "r1"})
      {:ok, second} = Token.from_response(%{"access_token" => "b", "refresh_token" => "r2"})

      assert Token.renewed(first, second).refresh_token == "r2"
    end
  end

  test "inspect says when it expires, never what it is" do
    {:ok, token} = Token.from_response(%{"access_token" => "at", "expires_in" => 60})

    assert inspect(token) =~ "expires in"
    refute inspect(token) =~ "at"
  end
end

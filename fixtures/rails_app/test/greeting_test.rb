require "test_helper"

class GreetingTest < ActionDispatch::IntegrationTest
  test "greeting is available" do
    get "/greeting"
    assert_response :success
  end
end

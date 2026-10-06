class GreetingsController < ActionController::Base
  def show
    render plain: "old"
  end
end

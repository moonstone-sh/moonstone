function love.draw()
	local windowWidth = love.graphics.getWidth()
	local windowHeight = love.graphics.getHeight()

	love.graphics.printf("Hello from LÖVE + Moonstone!", 0, windowHeight / 2, windowWidth, "center")
end

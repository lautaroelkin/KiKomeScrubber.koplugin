--[[
Fallback lines for the minutes the dataset has no quote for.

Edit freely: add, remove or reword lines. Rules:
  - {time} is replaced by the time in words ("twenty-seven minutes to ten"),
    highlighted like the time in a real quote. Every line needs it once.
  - When {time} starts the line, its first letter is capitalised for you.
  - The two families take turns (narrator, reader, narrator, ...); within a
    family the line is picked at random, never the same one twice in a row.
  - attribution: shown on the title/author line when "Show title and author"
    is on. Leave it empty ("") for no attribution line.

A syntax error here does not break the clock: the plugin falls back to the
plain time and logs a warning.
]]

return {
    -- A) Narrator: nothing worth telling happens at this time.
    narrator = {
        "At {time} nothing happened that anyone cared to record.",
        "At {time} the world went on, unremarked.",
        "Nothing worth writing down occurred at {time}.",
        "At {time} the story paused, as stories sometimes do.",
        "It was {time}, and for once nobody was watching.",
    },

    -- B) To the reader: the minute is left to them.
    reader = {
        "{time}. No author has claimed this minute yet. Perhaps you will.",
        "It is {time}, and this page is still blank. It's yours.",
        "{time}: an unwritten minute, waiting for someone to fill it.",
        "No one has written about {time} yet. Go on, then.",
        "{time}, and the line is left open for you.",
    },

    attribution = "",
}

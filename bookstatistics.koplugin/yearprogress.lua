local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local _ = require("gettext")
local Screen = Device.screen
local FFIUtil = require("ffi/util")
local N_ = _.ngettext
local T = FFIUtil.template


local LINE_COLOR = Blitbuffer.COLOR_GRAY_9
local BG_COLOR = Blitbuffer.COLOR_LIGHT_GRAY

-- Oh, hey, this one actually *is* an InputContainer!
local YearProgress = InputContainer:extend{
    padding = Size.padding.fullscreen,
}

function YearProgress:init()
    self.yearlyStats = self.main:getYearProgressStats(self.year)


    self.small_font_face = Font:getFace("smallffont")
    self.medium_font_face = Font:getFace("ffont")
    self.large_font_face = Font:getFace("largeffont")
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    if self.screen_width < self.screen_height then
        self.header_span = 20

        -- Высота отступа между блоками прогресса
        self.stats_span = 5
    else
        self.header_span = 5
        self.stats_span = 10
    end

    self.covers_fullscreen = true -- hint for UIManager:_repaint()
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:getStatusContent(self.screen_width),
    }
    -- We're full-screen, and the widget is built in a funky way, ensure dimen actually matches the full-screen,
    -- instead of only the content's effective area...
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_width, h = self.screen_height }

    if Device:hasKeys() then
        -- don't get locked in on non touch devices
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            }
        }
        self.ges_events.MultiSwipe = {
            GestureRange:new{
                ges = "multiswipe",
                range = function() return self.dimen end,
            }
        }
    end

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)


    
end



function YearProgress:getStatusContent(width)
    local title_bar = TitleBar:new{
        width = width,
        bottom_v_padding = 0,
        close_callback = not self.readonly and function() self:onClose() end,
        show_parent = self,

    }
    return VerticalGroup:new{
        align = "left",
        title_bar,
        --VerticalSpan:new{ width = Screen:scaleBySize(self.header_span), height = self.screen_height * (1/25) },
        self:genSingleHeader("Статистика " .. self.yearlyStats.year),
        self:genSummaryYear(width),
        self:genSingleHeader("Прогресс цели"),
        self:genYearlyProgress(width),
        self:genSingleHeader("Статистика по месяцам"),
        self:genMonthlyStats(),
        self:genFooter(),
    }
end


--Заголовок
function YearProgress:genSingleHeader(title)

    -- Текст заголовка
    local header_title = TextWidget:new{
        text = title,
        face = self.medium_font_face,
        fgcolor = LINE_COLOR,
    }
    local padding_span = HorizontalSpan:new{ width = self.padding }
    local line_width = (self.screen_width - header_title:getSize().w) / 2 - self.padding * 2


    -- Горизонтальная линия
    local line_container = LeftContainer:new{
        dimen = Geom:new{ w = line_width, h = self.screen_height * (1/25) },
        LineWidget:new{
            background = BG_COLOR,
            dimen = Geom:new{
                w = line_width,
                h = Size.line.thick,
            }
        }
    }


    return VerticalGroup:new{
        -- Отступ над заголовком 1/25
        --VerticalSpan:new{ width = Screen:scaleBySize(self.header_span), height = self.screen_height * (1/25) },
        HorizontalGroup:new{
            align = "center",
            padding_span,
            line_container,
            padding_span,
            header_title,
            padding_span,
            line_container,
            padding_span,
        },

        -- Отступ под заголовком 1/25

        --VerticalSpan:new{ width = Size.span.vertical_large, height = self.screen_height * (1/25) },
    }
end




function YearProgress:genMonthlyStats()
    local height = Screen:scaleBySize(55)
    local statistics_container = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width , h = height },
    }
    local statistics_group = VerticalGroup:new{ align = "left" }
    local top_padding_span = HorizontalSpan:new{ width = Screen:scaleBySize(5) }
    local top_span_group = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ h = Screen:scaleBySize(5) },
            top_padding_span
        },
    }
    table.insert(statistics_group, top_span_group)



    local padding_span = HorizontalSpan:new{ width = Screen:scaleBySize(15) }
    local span_group = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ h = Screen:scaleBySize(self.stats_span) },
            padding_span
        },
    }

    -- Lines have L/R self.padding. Make this section even more indented/padded inside the lines
    local inner_width = self.screen_width - 4*self.padding

    -- Перебираем дни и вставляем для каждого блоки статистики

    for i = 1, 12 do
         
        local month_string = tostring(self.yearlyStats.months[i].text)
        if month_string == "май" then
            month_string = "Май"
        end
        if (self.yearlyStats.months[i].pages ~= 0) then
            month_string = month_string .. " — " .. tostring(self.yearlyStats.months[i].pages) .. " стр."
        end
        if (self.yearlyStats.months[i].books ~= 0) then
            local books_in_month = tostring(self.yearlyStats.months[i].books)
            month_string = month_string .. " — " .. T(N_("1 book", "%1 books", books_in_month), books_in_month)
        end

        local total_group = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = inner_width , h = height * (1/3) },
                TextWidget:new{
                    padding = Size.padding.small,
                    text = month_string,
                    face = Font:getFace("smallffont"),
                },
            },
        }
        


        -- ПРОГРЕСС-БАР

        local max = self.yearlyStats.maxPagesInMonth
        local val = self.yearlyStats.months[i].pages

        local progress_width = 0
        if max > 0 then
            progress_width = math.floor(inner_width * val / max)
        end

        
        
        local titles_group = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = inner_width , h = height * (1/3) },
                ProgressWidget:new{
                    width = progress_width,
                    height = Screen:scaleBySize(14),
                    percentage = 1.0,
                    ticks = nil,
                    last = nil,
                    margin_h = 0,
                    margin_v = 0,
                }
            },
            
        }
        table.insert(statistics_group, total_group)
        table.insert(statistics_group, titles_group)
        table.insert(statistics_group, span_group)
    end  --for i=1




    table.insert(statistics_container, statistics_group)


    -- Центральный контейнер с блоками статистики
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width, h = math.floor(self.screen_height * 0.65) },
        statistics_container,
        
    }
end





function YearProgress:genFooter()

    local footer_height = math.floor(self.screen_height * 0.03)

    local forvard_enabled = true
    local current_year = tonumber(os.date("%Y", os.time()))

    if self.year >= current_year then
        forvard_enabled = false
    end

    local buttons_group = HorizontalGroup:new{
        align = "center",
        Button:new{
            icon = "chevron.left",
            callback = function() self:showPrevYear() end,
            bordersize = 0,
            show_parent = self,
            icon_height = footer_height,
            height = footer_height,
        },
        HorizontalSpan:new{
            width = Screen:scaleBySize(32),
        },
        Button:new{
            text = "Текущий год",
            callback = function() self:showCurrentYear() end,
            bordersize = 0,
            show_parent = self,
            height = footer_height,
            text_font_bold = false,
        },
        HorizontalSpan:new{
            width = Screen:scaleBySize(32),
        },
        Button:new{
            icon = "chevron.right",
            icon_height = footer_height,
            height = footer_height,
            callback = function() self:showNextYear() end,
            bordersize = 0,
            show_parent = self,
            enabled = forvard_enabled,
        },
        
    }


    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width, h = footer_height },
        buttons_group, 
    }
end



function YearProgress:showPrevYear()
    UIManager:close(self)
    UIManager:show(self:new{
        year = self.year - 1 ,
        main = self.main
    })
    return true
end


function YearProgress:showNextYear()
    UIManager:close(self)
    UIManager:show(self:new{
        year = self.year + 1 ,
        main = self.main
    })
    return true
end

function YearProgress:showCurrentYear()
    local year = tonumber(os.date("%Y", os.time()))
    UIManager:close(self)
    UIManager:show(self:new{
        year = year,
        main = self.main
    })
    return true
end






function YearProgress:genYearlyProgress(width)
    local inner_width = self.screen_width - 4*self.padding

    local goal = self.yearlyStats.goal

    if goal == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.screen_width, h = 40 },
            TextWidget:new{
                text = "Цель на год не выбрана",
                face = self.small_font_face,
            },
        }
    end

    local read = self.yearlyStats.books

    if read > goal then
        read = goal
    end

    local percentage = math.floor(read * 100  / goal) / 100

    local ticks = nil

    if goal <= 50 and goal > 1 then
        ticks = {}
        for i = 1, goal do
            table.insert(ticks, i)
        end
    end


    local progress_container = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = inner_width , h = 20 },
            ProgressWidget:new{
                width = inner_width,
                height = Screen:scaleBySize(20),
                percentage = percentage,
                ticks = ticks,
                last = goal,
                margin_h = 0,
                margin_v = 0,
            }
        },
    }


    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width, h = 40 },
        progress_container,
    }
end




function YearProgress:genSummaryYear(width)
    local height = Screen:scaleBySize(60)
    local statistics_container = CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
    }
    local statistics_group = VerticalGroup:new{ align = "left" }
    local tile_width = width * (1/4)
    local tile_height = height * (1/3)
    local user_duration_format = G_reader_settings:readSetting("duration_format")


    local months_from_year_start = 12
    local year = tonumber(os.date("%Y", os.time()))
    if year == self.year then
        months_from_year_start = tonumber(os.date("%m", os.time()))
    end






    local total_group = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextBoxWidget:new{
                alignment = "center",
                text = "Прочитано\nкниг",
                face = self.small_font_face,
                width = tile_width * 0.95,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextBoxWidget:new{
                alignment = "center",
                --text = _("Total\ntime"),
                text = "Цель\n(прочитать книг)",
                face = self.small_font_face,
                width = tile_width * 0.95,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextBoxWidget:new{
                alignment = "center",
                text = "Прочитано страниц",
                face = self.small_font_face,
                width = tile_width * 0.95,
            }
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextBoxWidget:new{
                alignment = "center",
                text = "В среднем\nстраниц в месяц",
                face = self.small_font_face,
                width = tile_width * 0.95,
            }
        }
    }

    local padding_span = HorizontalSpan:new{ width = Screen:scaleBySize(15) }
    local span_group = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ h = Size.span.horizontal_default },
            padding_span
        },
    }

    local data_group = HorizontalGroup:new{
        align = "center",





        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = tostring(self.yearlyStats.books),
                face = self.medium_font_face,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = tostring(self.yearlyStats.goal),
                face = self.medium_font_face,
            },
        },

        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = tostring(self.yearlyStats.pages),
                face = self.medium_font_face,
            }
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = math.floor(self.yearlyStats.pages / months_from_year_start),
                face = self.medium_font_face,
            }
        }









    }
    table.insert(statistics_group, total_group)
    table.insert(statistics_group, span_group)
    table.insert(statistics_group, data_group)
    table.insert(statistics_container, statistics_group)

    -- Верхний контейнер
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width , h = math.floor(self.screen_height * 0.09) },
        statistics_container,
    }
end

function YearProgress:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        -- Allow easier closing with swipe up/down
        self:onClose()
    elseif ges_ev.direction == "east" or ges_ev.direction == "west" or ges_ev.direction == "north" then
        -- no use for now
        do end -- luacheck: ignore 541
    else -- diagonal swipe
        -- trigger full refresh
        UIManager:setDirty(nil, "full")
        -- a long diagonal swipe may also be used for taking a screenshot,
        -- so let it propagate
        return false
    end
end

function YearProgress:onClose()
    UIManager:close(self)
    
    return true
end
YearProgress.onAnyKeyPressed = YearProgress.onClose
-- For consistency with other fullscreen widgets where swipe south can't be
-- used to close and where we then allow any multiswipe to close, allow any
-- multiswipe to close this widget too.
YearProgress.onMultiSwipe = YearProgress.onClose

 
return YearProgress

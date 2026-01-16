local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Math = require("optmath")
local ReadHistory = require("readhistory")
local SQ3 = require("lua-ljsqlite3/init")
local SyncService = require("frontend/apps/cloudstorage/syncservice")

local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local N_ = _.ngettext
local T = ffiUtil.template
local YearProgress = require("yearprogress")
local Utf8Proc = require("ffi/utf8proc")
local BookStatusWidget = require("ui/widget/bookstatuswidget")
local ReaderStatus = require("apps/reader/modules/readerstatus")
local filemanagerutil = require("apps/filemanager/filemanagerutil")



local dbutils = require("dbutils")

local db_location = DataStorage:getSettingsDir() .. "/bookstatistics.sqlite3"
local statistic_db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local MAX_PAGETURNS_BEFORE_FLUSH = 50
local DEFAULT_MIN_READ_SEC = 5
local DEFAULT_MAX_READ_SEC = 120
local DEFAULT_CALENDAR_START_DAY_OF_WEEK = 2 -- Monday
local DEFAULT_CALENDAR_NB_BOOK_SPANS = 3
local DEFAULT_YEARLY_BOOK_GOAL = 20








local BookStatistics = Widget:extend{
    name = "bookstatistics",
    is_doc_only = false,
    curr_page = 0,
    id_curr_book = nil,
    is_enabled = nil,
    convert_to_db = nil, -- true when migration to DB has been done
    pageturn_count = 0,
    mem_read_time = 0,
    mem_read_pages = 0,
    book_read_pages = 0,
    book_read_time = 0,
    avg_time = nil,
    page_stat = nil, -- Dictionary, indexed by page (hash), contains a list (array) of { timestamp, duration } tuples.
    data = nil, -- table
    doc_md5 = nil,
}


BookStatistics.default_settings = {
    min_sec = DEFAULT_MIN_READ_SEC,
    max_sec = DEFAULT_MAX_READ_SEC,
    freeze_finished_books = false,
    is_enabled = true,
    convert_to_db = nil,
    calendar_start_day_of_week = DEFAULT_CALENDAR_START_DAY_OF_WEEK,
    calendar_nb_book_spans = DEFAULT_CALENDAR_NB_BOOK_SPANS,
    calendar_show_histogram = true,
    calendar_browse_future_months = false,
    color = false,
    yearly_book_goal = DEFAULT_YEARLY_BOOK_GOAL,
}







function BookStatistics:onDispatcherRegisterActions()
    print("nothing")
    -- Dispatcher:registerAction("helloworld_action", {category="none", event="HelloWorld", title=_("Hello World"), general=true,})
end





function BookStatistics:init()

    self.is_doc = false
    self.is_doc_not_frozen = false -- freeze finished books statistics

    -- Placeholder until onReaderReady
    self.data = {
        title = "",
        authors = "N/A",
        pages = 0,
        path = ""
    }

    self.color = self:useColorRendering()
    self.settings = G_reader_settings:readSetting("bookstatistics", self.default_settings)
    dbutils.checkInitDatabase()
    
    self:updateMonthlyStats()

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

end


-- Извлекаем данные из открытой книги

function BookStatistics:getBookData()
    self.data.title = self.ui.doc_props.display_title
    self.data.authors = self.ui.doc_props.authors or "N/A"
    self.data.pages = self.ui.doc_settings:readSetting("doc_pages")
    self.data.path = self.ui.doc_settings:readSetting("doc_path")
end







function BookStatistics:addToMainMenu(menu_items)

    local statistic_menu_items = {{
        text = _("Settings"),
        sub_item_table = self:genSettingsSubItemTable(),
    }}

    if self.document and not self.document.is_pic then
        table.insert(statistic_menu_items, {
            text = "Настройки текущей книги",
            sub_item_table = self:genCurrentBookSettingsSubItemTable(),
            separator = true,
        })
    end

    table.insert(statistic_menu_items, {
        text = "Прочитанные книги",
        keep_menu_open = true,
        callback = function()
            self:onShowBookList()
        end,
    })

    table.insert(statistic_menu_items, {
        text = "Годовой прогресс прочитанного",
        keep_menu_open = true,
        callback = function()
            if self.ui.doc_settings ~= nil then
                self.ui.doc_settings:flush()
            end
            local year = tonumber(os.date("%Y", os.time()))
            UIManager:show(YearProgress:new{
                year = year,
                main = self
            })
        end,
    })

    
    menu_items.bookstatistics = {
        text = "Дополнительная статистика",
        sorting_hint = "tools",
        sub_item_table = statistic_menu_items,
    }
end


function BookStatistics:genSettingsSubItemTable()
    local sub_item_table = {
        {
            text_func = function()
                local year = tonumber(os.date("%Y", os.time()))
                local goal = tonumber(dbutils.getYearlyGoal(year))
                return T("Установить цель на этот год: %1 книг", goal)
            end,
            callback = function(touchmenu_instance)
                local year = tonumber(os.date("%Y", os.time()))
                local goal = tonumber(dbutils.getYearlyGoal(year))
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    value = goal,
                    value_min = 1,
                    value_max = 300,
                    default_value  = DEFAULT_YEARLY_BOOK_GOAL,
                    ok_text = _("Set"),
                    title_text =  "Хочу прочитать за год",
                    info_text = "Установить цель, сколько книг я хочу прочитать за этот год.",
                    callback = function(spin)
                        goal = spin.value
                        dbutils.setYearlyGoal(year, goal)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
            keep_menu_open = true,
        }
    }

    table.insert(sub_item_table, {
        text = "Обновить месячную статистику страниц",
        keep_menu_open = true,
        callback = function()
            self:rewriteMonthlyStats()
        end,
        separator = false,
    })


    return sub_item_table
end


function BookStatistics:genCurrentBookSettingsSubItemTable()

    local sub_item_table = {}

    if self.document then
        self:getBookData()
        local numOfSessions = dbutils.getNumOfSessions(self.data)
        local isIgnored = dbutils.getIgnoreMark(self.data)
        
        table.insert(sub_item_table, {
            text = "Не учитывать книгу в прочитанном",
            checked_func = function() return dbutils.getIgnoreMark(self.data) == 1 end,
            keep_menu_open = true,
            callback = function()
                dbutils.toggleIgnoreMark(dbutils.getIgnoreMark(self.data), self.data)
            end,
            enabled_func = function() return dbutils.bookInCompletedHistory(self.data) == true end,
            separator = false,
        })

        

        table.insert(sub_item_table, {
            text = "Установить дату прочтения",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local now_t = os.date("*t")
                local curr_year = now_t.year
                local curr_month = now_t.month
                local curr_day = now_t.day
                local DateTimeWidget = require("ui/widget/datetimewidget")
                local date_widget = DateTimeWidget:new{
                    year = curr_year,
                    month = curr_month,
                    day = curr_day,
                    ok_text = _("Set date"),
                    title_text = _("Set date"),
                    info_text = _("Date is in years, months and days."),
                    callback = function(time)
                        local timestamp = os.time{year=time.year, month=time.month, day=time.day, hour=0, min=0 }
                        dbutils.setBookCompletionDate(timestamp, self.data)
                        self:setBookRead()
                        touchmenu_instance:updateItems()
                    end
                }
                UIManager:show(date_widget)
            end,
            enabled_func = function()
                return self.data.title
            end,
        })


        table.insert(sub_item_table, {
            text = "Удалить отметку прочтения",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = "Удалить отметку прочтения",
                    cancel_text = _("Cancel"),
                    cancel_callback = function()
                        return
                    end,
                    ok_text = "Удалить",
                    ok_callback = function()
                        dbutils.deleteLastCompletionMark(self.data)
                        self:setBookUnread()
                        touchmenu_instance:updateItems()
                    end
                }) 
            end,


            enabled_func = function() return dbutils.bookInCompletedHistory(self.data) == true end,
            separator = false,
        })

        


        table.insert(sub_item_table, {
            text = "Перечитать книгу заново",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = "Начать новую сессию для данной книги? После прочтения она заново добавится в историю прочитанного.",
                    cancel_text = _("Cancel"),
                    cancel_callback = function()
                        return
                    end,
                    ok_text = "Перечитать",
                    ok_callback = function()
                        self:addNewBookReading(self.data)
                        self:setBookUnread()
                        --book_completed = false
                        numOfSessions = numOfSessions + 1
                        touchmenu_instance:updateItems()
                    end
                }) 
            end,
            enabled_func = function()
                return dbutils.bookInCompletedHistory(self.data) == true
            end,
            separator = false,
        })
        

        table.insert(sub_item_table, {
            text = "Отменить перечитывание книги",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = "Удалить последнюю сесию для данной книги? Книга больше не будет заново добавляться в прочитанные.",
                    cancel_text = _("Cancel"),
                    cancel_callback = function()
                        return
                    end,
                    ok_text = _("Set"),
                    ok_callback = function()
                        dbutils.removeLastBookReading(self.data)
                        numOfSessions = numOfSessions - 1
                        touchmenu_instance:updateItems()
                    end
                })
            end,
            enabled_func = function() return numOfSessions > 1 end,
            separator = true,
        })

        
       

    end

    return sub_item_table

    
end





function BookStatistics:useColorRendering()
    return Device:hasColorScreen() and (not G_reader_settings:has("color_rendering") or G_reader_settings:isTrue("color_rendering"))
end

function BookStatistics:onColorRenderingUpdate()
    self.color = self:useColorRendering()
end


















function BookStatistics:createDB(conn)

    -- Make it WAL, if possible
    if Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end

    conn:exec([[
        CREATE TABLE IF NOT EXISTS book_completed
            (
                id integer PRIMARY KEY autoincrement,
                read_count integer NOT NULL DEFAULT 1,
                completed integer NOT NULL DEFAULT 0,
                completed_ts integer NOT NULL DEFAULT 0,
                ignore integer NOT NULL DEFAULT 0,
                title text,
                authors text,
                path text,
                pages integer NOT NULL DEFAULT 0

            );
    ]])

    conn:exec([[
        CREATE TABLE IF NOT EXISTS year_goal
            (
                year integer PRIMARY KEY,
                goal integer
            );
    ]])

    conn:exec([[
        CREATE TABLE IF NOT EXISTS month_statistics
            (
                id integer PRIMARY KEY autoincrement,
                year integer,
                month integer,
                pages_read integer NOT NULL DEFAULT 0,
                time_reading integer NOT NULL DEFAULT 0
            );
    ]])

    

end




-- Извленкаем данные о страницах и времени из плагина статистики и сохраняем данные за месяц, если они отсутствуют.
-- Мы хотим сохранить подсчитанные данные вместо того, чтобы считать их каждый раз заново, чтобы ускорить загрузку трекеров.

function BookStatistics:updateMonthlyStats()
    local now_t = os.date("*t")
    local current_year = now_t.year
    local current_month = now_t.month
    local prev_month = current_month - 1
    local prev_month_year = current_year
    if prev_month == 0 then
        prev_month = 12
        prev_month_year = current_year - 1
    end


    local current_month_start = os.time{year=current_year, month=current_month, day=1, hour=0, min=0 }

    -- Проверяем, есть ли запись за предыдущий месяц
    local last_existing = dbutils.checkLastExistingMonth()
    local last_existing_year = last_existing[1]
    local last_existing_month = last_existing[2]


    if last_existing_year == nil then
        -- Статистика пустая, нужно обновить всё
        --UIManager:show(InfoMessage:new{text = "Статистика пустая", timeout = 10 })
        local result_months = dbutils.getMonthStatisticsBeforeDate(current_month_start)
        dbutils.saveCalculatedMonthStats(result_months)
    else
        
        if last_existing_month ~= prev_month or last_existing_year ~= prev_month_year then
            -- Нет статистики последнего месяца, нужно обновить частично

            local first_not_existing_year = last_existing_year
            local first_not_existing_month = last_existing_month + 1
            
            if first_not_existing_month == 13 then
                first_not_existing_month = 1
                first_not_existing_year = last_existing_year + 1
            end

            local first_not_existing_ts = os.time{year=tonumber(first_not_existing_year), month=tonumber(first_not_existing_month), day=1, hour=0, min=0 }
            local result_months = dbutils.getMonthStatisticsBetweenDates(first_not_existing_ts, current_month_start)
            dbutils.saveCalculatedMonthStats(result_months)
        end
    end
end





-- Полностью перезаписываем данные о страницах и времени заново. 
-- Это делается только по команде в случае каких-то расхождений с плагином статистики.

function BookStatistics:rewriteMonthlyStats()
    local now_t = os.date("*t")
    local current_year = now_t.year
    local current_month = now_t.month
    local current_month_start = os.time{year=current_year, month=current_month, day=1, hour=0, min=0 }
    local result_months = dbutils.getMonthStatisticsBeforeDate(current_month_start)
    dbutils.clearMonthStatisticsDB()
    dbutils.saveCalculatedMonthStats(result_months)
    --UIManager:show(InfoMessage:new{text = "Статистика обновлена", timeout = 10 })
end







-- Выполняется при открытии книги

function BookStatistics:onReaderReady(config)
    UIManager:nextTick(function()
        if self.settings.is_enabled then
            self:getBookData()
            self.view.footer:maybeUpdateFooter()
        end
    end)
end
























function BookStatistics:setBookRead()
    local summary = self.ui.doc_settings:readSetting("summary")
    if summary == nil then
        summary = {status = "complete"}
    else
        summary.status = "complete"
    end
    self.ui.doc_settings:saveSetting("summary", summary)
    
end








function BookStatistics:setBookUnread()
    local summary = self.ui.doc_settings:readSetting("summary")
    if summary ~= nil then
        summary.status = "reading"
    end
    self.ui.doc_settings:saveSetting("summary", summary)

end









-- Показать список книг

function BookStatistics:onShowBookList()

    local showIgnored = true
    local month_kv

    local columns = dbutils.getBookCompleteColumns()

    local ids = columns[1]
    local read_counts = columns[2]
    local timestamps = columns[3]
    local ignored = columns[4]
    local titles = columns[5]
    local authors = columns[6]
    local paths = columns[7]
    local all_pages = columns[8]

    local years = {}


    function manageBook(book, year)

        local button_dialog = {}
        local numOfSessions = dbutils.getNumOfSessions(book)
        
        
        local buttons = {
            {{
                text = book["title"] .. " - " .. book["authors"],
                avoid_text_truncation = true,
                menu_style = true,
                callback = function() return end,
                hold_callback = function() return true end,
            }},
            {{
                text = book["path"],
                avoid_text_truncation = true,
                menu_style = true,
                callback = function() return end,
                hold_callback = function() return true end,
            }},



        }

        local ignore_text = ""

        if book["ignore"] == 1 then
            ignore_text = "☑ Не учитывать книгу в прочитанном"
        else
            ignore_text = "☐ Не учитывать книгу в прочитанном"
        end

        table.insert(buttons, {{
            text = ignore_text,
            avoid_text_truncation = true,
            menu_style = true,
            callback = function() 
                dbutils.toggleIgnoreMark(book["ignore"], book)
                UIManager:close(button_dialog)
            end,
            hold_callback = function() return true end,
        }})



        local set_date_text = "Установить дату прочтения"


        if numOfSessions > 1 then
            set_date_text = "Установить дату прочтения для текущей сессии"

            table.insert(buttons, {{
                text = "Установить дату прочтения для выбранной сессии",
                avoid_text_truncation = true,
                menu_style = true,
                callback = function() 
                    local now_t = os.date("*t")
                    local curr_year = now_t.year
                    local curr_month = now_t.month
                    local curr_day = now_t.day
                    local DateTimeWidget = require("ui/widget/datetimewidget")
                    local date_widget = DateTimeWidget:new{
                        year = curr_year,
                        month = curr_month,
                        day = curr_day,
                        ok_text = _("Set date"),
                        title_text = _("Set date"),
                        info_text = _("Date is in years, months and days."),
                        callback = function(time)
                            local timestamp = os.time{year=time.year, month=time.month, day=time.day, hour=0, min=0 }
                            dbutils.updateCompletionDateForSelectedSession(timestamp, book)
                            year = os.date("%Y", timestamp)
                            UIManager:close(self.kv)
                            self:onShowBookList()
                            onSelectYear(year)

                        end
                    }
                    UIManager:show(date_widget)
                    UIManager:close(button_dialog)
                end,
                hold_callback = function() return true end,
            }})
            
        end



        table.insert(buttons, {{
            text = set_date_text,
            avoid_text_truncation = true,
            menu_style = true,
            callback = function() 
                local now_t = os.date("*t")
                local curr_year = now_t.year
                local curr_month = now_t.month
                local curr_day = now_t.day
                local DateTimeWidget = require("ui/widget/datetimewidget")
                local date_widget = DateTimeWidget:new{
                    year = curr_year,
                    month = curr_month,
                    day = curr_day,
                    ok_text = _("Set date"),
                    title_text = _("Set date"),
                    info_text = _("Date is in years, months and days."),
                    callback = function(time)
                        local timestamp = os.time{year=time.year, month=time.month, day=time.day, hour=0, min=0 }
                        dbutils.updateLastSessionCompletionDate(timestamp, book)
                        year = os.date("%Y", timestamp)
                        UIManager:close(self.kv)
                        self:onShowBookList()
                        onSelectYear(year)

                    end
                }
                UIManager:show(date_widget)
                UIManager:close(button_dialog)
            end,
            hold_callback = function() return true end,
        }})


        



        table.insert(buttons, {{
            text = "Удалить отметку прочтения",
            avoid_text_truncation = true,
            menu_style = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "Удалить отметку прочтения",
                    cancel_text = _("Cancel"),
                    cancel_callback = function()
                        return
                    end,
                    ok_text = "Удалить",
                    ok_callback = function()
                        dbutils.deleteLastCompletionMark(book)
                        self:setBookUnread()
                        UIManager:close(self.kv)
                        self:onShowBookList()
                    end
                })
                UIManager:close(button_dialog)  
            end,
            hold_callback = function() return true end,
        }})




        table.insert(buttons, {{
            text = "Перечитать книгу заново",
            avoid_text_truncation = true,
            menu_style = true,
            callback = function() 
                UIManager:show(ConfirmBox:new{
                    text = "Начать новую сессию для данной книги? После прочтения она заново добавится в историю прочитанного.",
                    cancel_text = _("Cancel"),
                    cancel_callback = function()
                        return
                    end,
                    ok_text = "Перечитать",
                    ok_callback = function()
                        self:addNewBookReading(book)
                        self:setBookUnread()
                        numOfSessions = numOfSessions + 1
                    end
                }) 
                UIManager:close(button_dialog)
            end,
            hold_callback = function() return true end,
        }})


        if numOfSessions > 1 then
            table.insert(buttons, {{
                text = "Отменить перечитывание книги",
                avoid_text_truncation = true,
                menu_style = true,
                callback = function() 
                    UIManager:show(ConfirmBox:new{
                        text = "Удалить последнюю сесию для данной книги? Книга больше не будет заново добавляться в прочитанные.",
                        cancel_text = _("Cancel"),
                        cancel_callback = function()
                            return
                        end,
                        ok_text = _("Set"),
                        ok_callback = function()
                            dbutils.removeLastBookReading(book)
                            --numOfSessions = numOfSessions - 1
                            UIManager:close(self.kv)
                            self:onShowBookList()
                        end
                    })
                    UIManager:close(button_dialog)
                end,
                hold_callback = function() return true end,
            }})
        end

        
        

        button_dialog = ButtonDialog:new{
            buttons = buttons,
        }
        UIManager:show(button_dialog)
    end



    function getBookPairs(year)

        local books = years[year]["books"]

        local books_sort = {}
        for key, val in pairs(books) do
            table.insert(books_sort, val)
        end

        table.sort(books_sort, function(a, b) 
            return a["ts"] > b["ts"]
        end)




        local book_pairs = {}

        for i, book_values in ipairs(books_sort) do
            local book_row = { 
                book_values["title"],
                book_values["date"],
                callback = function()
                    manageBook(book_values, year)
                end
            }
            table.insert(book_pairs, book_row)
        end
        return book_pairs
    end





    function onSelectYear(year)

        local book_pairs = getBookPairs(year)
        local kv = self.kv
        UIManager:close(self.kv)
        self.kv = KeyValuePage:new{
            title = year,
            middle_padding = 20,
            kv_pairs = book_pairs,
            callback_return = function()
                UIManager:show(kv)
                self.kv = kv
            end,
            close_callback = function() self.kv = nil end, -- clean stack
        }


        UIManager:show(self.kv)
    end



    function getYearPairs()
        
        local years_sort = {}
        for key,_ in pairs(years) do
            table.insert(years_sort, key)
        end

        table.sort(years_sort, function(a, b) return a > b end)

        local year_pairs = {}

        for i, year in ipairs(years_sort) do
            local year_values = years[year]

            local year_row = { 
                year,
                T(N_("1 book", "%1 books", year_values["books_count"]), year_values["books_count"]),
                callback = function()
                    onSelectYear(year)
                end
            }
            table.insert(year_pairs, year_row)
        end
        return year_pairs
    end


    for i = 1, #ids do 
        local id = ids[i]
        local ts_string = timestamps[i]
        local timestamp = tonumber(ts_string)
        local year = os.date("%Y", timestamp)
        local month = os.date("%m", timestamp)
        local month_string = datetime.longMonthTranslation[os.date("%B", timestamp)]
        local datestring = os.date("%Y-%m-%d", timestamp)

        local book_data = {
            ["id"] = id,
            ["title"] = titles[i],
            ["authors"] = authors[i],
            ["date"] = datestring,
            ["path"] = paths[i],
            ["ignore"] = ignored[i],
            ["ts"] = timestamp,
            ["pages"] = all_pages[i],
            ["read_count"] = read_counts[i]
        }
        
        if years[year] == nil then
            years[year] = {
                ["books_count"] = 1,
                ["books"] = {
                    [id] = book_data
                }
            }
        else
            years[year]["books_count"] = years[year]["books_count"] + 1
            years[year]["books"][id] = book_data
        end 
    end


    
    

    local year_pairs = getYearPairs()

    if #year_pairs > 0 then
        self.kv = KeyValuePage:new{
            title = "Список прочитанных книг",
            return_button = true,
            kv_pairs = year_pairs
        }
        UIManager:show(self.kv)
    else
        UIManager:show(InfoMessage:new{text ="Нет прочитанных книг", timeout = 3 })
    end
    
    
    



end



















function BookStatistics:getYearProgressStats(year)
    

    local yearlyStats = {
        year = year,
        goal = tonumber(dbutils.getYearlyGoal(year)),
        books = 0,
        pages = 0,
        months = {},
        maxPagesInMonth = 0
    }
    local yearlyBooks = 0
    local yearlyPages = 0
    local months = {}
    local maxPagesInMonth = 0

    local now_t = os.date("*t")
    local current_year = now_t.year
    local current_month = now_t.month
    local current_month_start = os.time{year=current_year, month=current_month, day=1, hour=0, min=0 }
    
    local current_month_pages = 0

    if year == current_year then
        current_month_pages = dbutils.getMonthPagesSinceDate(current_month_start)
    end


    

    local conn = SQ3.open(db_location)
    
    -- Перебираем месяцы
    for i = 1, 12 do

        local start_month = os.time{year=year, month=i, day=1, hour=0, min=0 }
        local end_month
        if i ~= 12 then
            end_month = os.time{year=year, month=i + 1, day=1, hour=0, min=0 }
        else
            end_month = os.time{year=year + 1, month=1, day=1, hour=0, min=0 }
        end

        local monthlyStats = {
            text = datetime.longMonthTranslation[os.date("%B", start_month)],
            books = 0,
            pages = 0,
        }
        local monthlyBooks = 0
        local monthlyPages = 0

        -- Извлекаем количество страниц



        if year == current_year and i == current_month then
            monthlyPages = current_month_pages
        else
            monthlyPages = dbutils.getMonthlyPages(conn, year, i)
        end

        

        if monthlyPages == nil then
            monthlyPages = 0
        end
        monthlyPages = tonumber(monthlyPages)

        -- Извлекаем количество книг

        local monthlyBooks = dbutils.getMonthlyBooks(conn, start_month, end_month)

        if monthlyBooks == nil then
            monthlyBooks = 0
        end
        monthlyBooks = tonumber(monthlyBooks)

        local month_date = os.date("%Y-%m", start_month)

        monthlyStats.books = monthlyBooks
        monthlyStats.pages = monthlyPages
        yearlyBooks = yearlyBooks + monthlyBooks
        yearlyPages = yearlyPages + monthlyPages
        table.insert(months, i, monthlyStats)

        if monthlyPages > maxPagesInMonth then
            maxPagesInMonth = monthlyPages
        end
    end

    conn:close()

    

    yearlyStats.books = yearlyBooks
    yearlyStats.pages = yearlyPages
    yearlyStats.months = months
    yearlyStats.maxPagesInMonth = maxPagesInMonth
    return yearlyStats  
    
end

















-- Патчим существующие методы отметки книг, чтобы они вызывали нашу функцию для сохранения даты завершения

-- При отметке прочтения из окна статуса книги
BookStatusWidget.onChangeBookStatus_orig = BookStatusWidget.onChangeBookStatus

BookStatusWidget.onChangeBookStatus = function(self, option_name, option_value)
    self:onChangeBookStatus_orig(option_name, option_value)

    local data = {
        title = self.ui.doc_props.display_title,
        authors = self.ui.doc_props.authors or "N/A",
        path = self.ui.doc_settings:readSetting("doc_path"),
        pages = self.ui.doc_settings:readSetting("doc_pages")
    }

    if option_name[option_value] == "complete" then
        dbutils.onBookMarkedAsComplete(data)
    end
end


-- При отметке прочтения при завершении книги
ReaderStatus.markBook_orig = ReaderStatus.markBook

ReaderStatus.markBook = function(self, mark_read)
    self:markBook_orig(mark_read)

    local data = {
        title = self.ui.doc_props.display_title,
        authors = self.ui.doc_props.authors or "N/A",
        path = self.ui.doc_settings:readSetting("doc_path"),
        pages = self.ui.doc_settings:readSetting("doc_pages")
    }

    local summary = self.ui.doc_settings:readSetting("summary")
    if summary.status == "complete" then
        dbutils.onBookMarkedAsComplete(data)
    end
end


-- При отметке прочтения из меню в файловом менеджере - ???

filemanagerutil.saveSummary_orig = filemanagerutil.saveSummary

filemanagerutil.saveSummary = function(doc_settings_or_file, summary)
    doc_settings_or_file = filemanagerutil.saveSummary_orig(doc_settings_or_file, summary)

    local data = {
        title = doc_settings_or_file.data.doc_props.title,
        authors = doc_settings_or_file.data.doc_props.authors,
        path = doc_settings_or_file:readSetting("doc_path"),
        pages = doc_settings_or_file:readSetting("doc_pages")
    }

    if summary.status == "complete" then
        dbutils.onBookMarkedAsComplete(data)
    end
    return doc_settings_or_file
end




return BookStatistics




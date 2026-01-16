local SQ3 = require("lua-ljsqlite3/init")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local db_location = DataStorage:getSettingsDir() .. "/bookstatistics.sqlite3"
local statistic_db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"


local dbutils = {}




function dbutils.checkInitDatabase()
    local conn = SQ3.open(db_location)

    if not conn:exec("PRAGMA table_info('book_completed');") then
        UIManager:show(ConfirmBox:new{
            text = "Do you want to create an empty database?",
            cancel_text = _("Close"),
            cancel_callback = function()
                return
            end,
            ok_text = _("Create"),
            ok_callback = function()
                local conn_new = SQ3.open(db_location)
                self:createDB(conn_new)
                conn_new:close()
                UIManager:show(InfoMessage:new{text =_("A new empty database has been created."), timeout = 3 })
            end,
        })
    end
    conn:close()
end


-- Отметка игнорирования

function dbutils.getIgnoreMark(data)
    local conn = SQ3.open(db_location)
    local isIgnored = conn:rowexec(string.format([[
        SELECT ignore
        FROM book_completed
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        LIMIT 1;
    ]]))
    conn:close()
    return isIgnored
end



function dbutils.toggleIgnoreMark(isIgnored, data)
    if isIgnored == 0 then
        isIgnored = 1
    else
        isIgnored = 0
    end
    local conn = SQ3.open(db_location)
    local isIgnored = conn:rowexec(string.format([[
        UPDATE book_completed
        SET ignore = ]] .. isIgnored .. [[
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[";
    ]]))
    conn:close()
end



function dbutils.deleteLastCompletionMark(data)
    local conn = SQ3.open(db_location)
    conn:rowexec([[
        UPDATE book_completed
        SET completed = 0
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND completed = 1 AND read_count = (
            SELECT max(read_count) FROM book_completed WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]])
    conn:close()
end



function dbutils.getNumOfSessions(data)
    local conn = SQ3.open(db_location)
    local max_read_count = conn:rowexec(string.format([[
        SELECT max(read_count) 
        FROM book_completed 
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[";
    ]]))
    conn:close()

    if max_read_count ~= nil then
        return tonumber(max_read_count)
    else
        return 0
    end
end




-- Выполняется, когда книга отмечена как прочитанная в коридере (любым из стандартных способов)
function dbutils.onBookMarkedAsComplete(data)
    local ts = os.time()

    -- Проверить, есть ли запись о книге
    local conn = SQ3.open(db_location)
    local existing_stat = conn:rowexec([[
        SELECT completed
        FROM book_completed
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
            SELECT max(read_count) FROM book_completed 
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]])
    
    if existing_stat == nil then
        -- Запись о книге не существует, добавляем новую
        conn:exec([[
            INSERT INTO book_completed
            VALUES (NULL, 1, 1, ]] .. ts .. [[, 0, "]] .. data.title .. [[", "]] .. data.authors .. [[", "]] .. data.path .. [[", ]] .. data.pages .. [[);
        ]])

    elseif existing_stat == 0 then
        -- Статистика завершения для этой книги существует, надо обновить статус и поставить выбранную дату
        local existing_stat = conn:rowexec(string.format([[
            UPDATE book_completed
            SET completed = 1, completed_ts = ]] .. ts .. [[
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
                SELECT max(read_count) FROM book_completed 
                WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
            );
        ]]))
    end
    conn:close()
end







function dbutils.getBookCompleteColumns()
    local conn = SQ3.open(db_location)
    local columns = conn:exec(string.format([[
        SELECT 
            CAST(id as text), 
            read_count,
            completed_ts,
            ignore,
            title, 
            authors, 
            path, 
            CAST(pages as text)
        FROM book_completed 
        WHERE completed = 1
        ORDER  BY completed_ts DESC;
    ]]))
    conn:close() 
    return columns
end







function dbutils.setYearlyGoal(year, goal)
    local conn = SQ3.open(db_location)
    conn:exec([[
        REPLACE INTO year_goal
        (year, goal)
        VALUES (]] .. year .. [[, ]] .. goal .. [[)
    ]])
    conn:close()
end





function dbutils.getYearlyGoal(year)
    local conn = SQ3.open(db_location)
    local goal = conn:rowexec([[
        SELECT goal
        FROM year_goal
        WHERE year = ]] .. year .. [[;
    ]])
    conn:close()
    if goal == nil then
        goal = 0
    end
    return goal
end








function dbutils.removeLastBookReading(data)
    local conn = SQ3.open(db_location)
    conn:rowexec([[
        DELETE FROM book_completed
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
            SELECT max(read_count) FROM book_completed WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]])
    conn:close()
end






function dbutils.addNewBookReading(data)
    local conn = SQ3.open(db_location)
    conn:exec([[
        INSERT INTO book_completed
        VALUES (NULL, (
            SELECT max(read_count) FROM book_completed 
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        ) + 1, 0, 0, 0, "]] .. data.title .. [[", "]] .. data.authors .. [[", "]] .. data.path .. [[", ]] .. data.pages .. [[);
    ]])
    conn:close()
end











-- Проверяем, есть ли книга в прочитанном

function dbutils.bookInCompletedHistory(data)
    local conn = SQ3.open(db_location)
    local book_completed = conn:rowexec(string.format([[
        SELECT completed
        FROM book_completed
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
            SELECT max(read_count) FROM book_completed 
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]]))
    conn:close()

    if book_completed ~= nil and book_completed ~= 0 then
        return true
    else
        return false
    end
end










function dbutils.updateCompletionDateForSelectedSession(ts, data)
    -- Этот метод используется только из режима просмотра списка прочитанных, поэтому мы можем быть уверены, 
    -- что запись о книге существует, нам не нужно дополнитеьно её проверять
    local conn = SQ3.open(db_location)
    conn:rowexec(string.format([[
        UPDATE book_completed
        SET completed = 1, completed_ts = ]] .. ts .. [[
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = "]] .. data.read_count .. [[";
    ]]))
    conn:close() 
end





function dbutils.updateLastSessionCompletionDate(ts, data)
    local conn = SQ3.open(db_location)
    conn:rowexec(string.format([[
        UPDATE book_completed
        SET completed = 1, completed_ts = ]] .. ts .. [[
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" 
        AND read_count = (
            SELECT max(read_count) FROM book_completed 
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]]))
    conn:close() 
end






function dbutils.setBookCompletionDate(ts, data)

    -- Проверить, есть ли запись о книге
    local conn = SQ3.open(db_location)
    local existing_stat = conn:rowexec([[
        SELECT completed
        FROM book_completed
        WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
            SELECT max(read_count) FROM book_completed 
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
        );
    ]])
    
    if existing_stat == nil then

        -- Запись о книге не существует, добавляем новую
        conn:exec([[
            INSERT INTO book_completed
            VALUES (NULL, 1, 1, ]] .. ts .. [[, 0, "]] .. data.title .. [[", "]] .. data.authors .. [[", "]] .. data.path .. [[", ]] .. data.pages .. [[);
        ]])

    else

        -- Статистика завершения для этой книги существует, надо обновить статус и поставить выбранную дату
        local existing_stat = conn:rowexec(string.format([[
            UPDATE book_completed
            SET completed = 1, completed_ts = ]] .. ts .. [[
            WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [[" AND read_count = (
                SELECT max(read_count) FROM book_completed 
                WHERE title = "]] .. data.title .. [[" AND authors = "]] .. data.authors .. [["
            );
        ]]))
    end

    conn:close()
end









function dbutils.getMonthPagesSinceDate(date)
    local stat_conn = SQ3.open(statistic_db_location)
    current_month_pages = stat_conn:rowexec(string.format(
        [[
            SELECT COUNT(*)
            FROM   (
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime')     AS dates,
                        start_time
                FROM   page_stat
                WHERE  start_time >= %d
                GROUP  BY id_book, page, dates
            )
            GROUP  BY dates
            ORDER  BY dates ASC;
        ]],
        date
    ))
    stat_conn:close()
    return current_month_pages
end













function dbutils.getMonthStatisticsBeforeDate(date)
    local stat_conn = SQ3.open(statistic_db_location)
    local result_months = stat_conn:exec(string.format(
        [[
            SELECT dates,
                CAST(count(*) AS text)             AS pages,
                CAST(sum(sum_duration) AS text)    AS durations,
                start_time
            FROM   (
                        SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime')     AS dates,
                                sum(duration)                                                 AS sum_duration,
                                start_time
                        FROM   page_stat
                        WHERE  start_time < %d
                        GROUP  BY id_book, page, dates
                )
            GROUP  BY dates
            ORDER  BY dates ASC;
        ]],
        date
    ))
    stat_conn:close()
    return result_months
end









function dbutils.getMonthStatisticsBetweenDates(start_date, end_date)
    local stat_conn = SQ3.open(statistic_db_location)
    local result_months = stat_conn:exec(string.format(
        [[
            SELECT dates,
                CAST(count(*) AS text)             AS pages,
                CAST(sum(sum_duration) AS text)    AS durations,
                start_time
            FROM   (
                        SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime')     AS dates,
                            sum(duration)                                                    AS sum_duration,
                            start_time
                        FROM   page_stat
                        WHERE  start_time BETWEEN %d AND %d
                        GROUP  BY id_book, page, dates
                )
            GROUP  BY dates
            ORDER  BY dates ASC;
        ]],
        start_date, 
        end_date
    ))
    stat_conn:close()
    return result_months
end






function dbutils.saveCalculatedMonthStats(result_months)
    local months = result_months[1]
    local months_pages = result_months[2]
    local durations = result_months[3]

    local conn = SQ3.open(db_location)

    for i = 1, #months do
        local pages = months_pages[i]
        local duration = durations[i]
        local month_name = months[i]
        local year_string = string.sub(month_name, 1, 4)
        local month_string = string.sub(month_name, 6, 7)

        if string.sub(month_string, 1, 1) == 0 then
            month_string = string.sub(month_string, 2, 2)
        end

        conn:exec([[
            INSERT INTO month_statistics
            VALUES (NULL, ]] .. year_string .. [[, ]] .. month_string .. [[, ]] .. pages .. [[, ]] .. duration .. [[);
        ]])
        
    end
    conn:close()
end



function dbutils.clearMonthStatisticsDB()
    local conn = SQ3.open(db_location)
    conn:exec([[
        DELETE FROM month_statistics
    ]])
    conn:exec([[
        DELETE FROM sqlite_sequence WHERE name='month_statistics'
    ]])
    conn:close()
end







function dbutils.getMonthlyPages(conn, year, month)
    monthlyPages = conn:rowexec(string.format(
        [[
            SELECT pages_read
            FROM month_statistics
            WHERE year = ]] .. tostring(year) .. [[ AND month = ]] .. tostring(month) .. [[;
        ]]
    ))
    return monthlyPages
end



function dbutils.getMonthlyBooks(conn, start_month, end_month)
    local monthlyBooks = conn:rowexec(string.format(
        [[
            SELECT COUNT(*)
            FROM book_completed
            WHERE completed = 1 AND ignore = 0 AND completed_ts BETWEEN %d AND %d
        ]], 
        start_month, 
        end_month
    ))
    return monthlyBooks
end








function dbutils.checkLastExistingMonth()
    local conn = SQ3.open(db_location)
    local last_existing_year, last_existing_month = conn:rowexec([[
        SELECT 
        CAST(year AS INTEGER), 
        CAST(month AS INTEGER)
        FROM month_statistics
        WHERE id = (
            SELECT max(id) FROM month_statistics
        );
    ]])
    conn:close()
    return {last_existing_year, last_existing_month}
end







return dbutils
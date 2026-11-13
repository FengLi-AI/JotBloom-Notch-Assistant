import Foundation

extension DatabaseMigrator {
    static func migrateVersionEightToNine(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.execute("""
                CREATE TABLE assistant_tasks (
                  id TEXT PRIMARY KEY NOT NULL,
                  title TEXT NOT NULL,
                  raw_input TEXT NOT NULL,
                  source_kind TEXT NOT NULL,         -- notchText, notchFiles, chat
                  chat_session_token TEXT,           -- 从对话发起时的会话，其他入口为空
                  chat_turn_token TEXT,              -- 从对话发起时的那一轮
                  status TEXT NOT NULL,
                  brief_json TEXT,                   -- 模型理解结果
                  plan_json TEXT,                    -- 模型给出的计划
                  scope_json TEXT,                   -- 用户批准的范围，只能由用户点击写入
                  due_at_ms INTEGER,
                  allow_network INTEGER NOT NULL DEFAULT 0,
                  agent TEXT,                        -- 第一阶段只有 codex
                  agent_thread_id TEXT,
                  agent_turn_id TEXT,
                  output_directory TEXT,
                  result_summary TEXT,
                  error_code TEXT,
                  created_at_ms INTEGER NOT NULL,
                  updated_at_ms INTEGER NOT NULL,
                  completed_at_ms INTEGER
                );
                CREATE INDEX assistant_tasks_status ON assistant_tasks(status, updated_at_ms DESC);
                CREATE INDEX assistant_tasks_chat_turn ON assistant_tasks(chat_turn_token);

                CREATE TABLE assistant_task_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  task_id TEXT NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL,
                  text TEXT NOT NULL,                -- 给用户看的大白话
                  created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX assistant_task_events_task ON assistant_task_events(task_id, id);

                CREATE TABLE assistant_task_steps (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  task_id TEXT NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE,
                  step_index INTEGER NOT NULL,
                  tool TEXT NOT NULL,
                  args_json TEXT NOT NULL,
                  decision TEXT NOT NULL,            -- allow, allowAndRecord, askUser, deny
                  state TEXT NOT NULL,               -- running, done, failed, unknown
                  result_text TEXT,                  -- 截断后的工具结果
                  undo_json TEXT,                    -- 可撤销操作的恢复信息
                  undone_at_ms INTEGER,
                  created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX assistant_task_steps_task ON assistant_task_steps(task_id, step_index);

                CREATE TABLE assistant_questions (
                  id TEXT PRIMARY KEY NOT NULL,
                  task_id TEXT NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL,                -- clarify, agentQuestion, approval, scope, budget, stuck, overtime, codexResult
                  payload_json TEXT NOT NULL,
                  rpc_request_id TEXT,               -- 批准请求的 JSON-RPC id
                  answer_json TEXT,
                  created_at_ms INTEGER NOT NULL,
                  answered_at_ms INTEGER
                );

                CREATE TABLE assistant_reminders (
                  id TEXT PRIMARY KEY NOT NULL,
                  task_id TEXT NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE,
                  fire_at_ms INTEGER NOT NULL,
                  state TEXT NOT NULL,               -- pending, delivered, missed, cancelled
                  delivered_at_ms INTEGER
                );
                CREATE INDEX assistant_reminders_due ON assistant_reminders(state, fire_at_ms);

                CREATE TABLE assistant_materials (
                  id TEXT PRIMARY KEY NOT NULL,
                  task_id TEXT NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL,                -- inspiration, prompt, file, chat
                  ref_id TEXT NOT NULL,              -- 灵感或提示词 id、文件路径，或聊天轮次 token
                  source TEXT NOT NULL DEFAULT 'plan', -- plan, auto, user：计划卡、执行中自动找到、用户添加
                  title_snapshot TEXT NOT NULL,
                  selected INTEGER NOT NULL DEFAULT 0,
                  sent_at_ms INTEGER
                );

                CREATE UNIQUE INDEX assistant_tasks_one_chat_turn ON assistant_tasks(chat_turn_token) WHERE chat_turn_token IS NOT NULL;
                CREATE TABLE assistant_task_links (
                  chat_turn_token TEXT PRIMARY KEY NOT NULL,
                  chat_session_token TEXT NOT NULL,
                  task_id TEXT REFERENCES assistant_tasks(id) ON DELETE SET NULL,
                  title_snapshot TEXT NOT NULL
                );
                CREATE TABLE assistant_composer_attachments (
                  chat_session_token TEXT PRIMARY KEY NOT NULL REFERENCES chat_sessions(token) ON DELETE CASCADE,
                  payload_json TEXT NOT NULL
                );
                PRAGMA user_version=9;
                """, operation: "migrate_v9_assistant")
            try validateVersionNine(db)
        }
    }
    static func validateVersionNine(_ db: SQLiteConnection) throws {
        // Preserve all previous-schema checks as well as every new column and index.
        try validateVersionEight(db)
        _ = try db.prepare("SELECT id,title,raw_input,source_kind,chat_session_token,chat_turn_token,status,brief_json,plan_json,scope_json,due_at_ms,allow_network,agent,agent_thread_id,agent_turn_id,output_directory,result_summary,error_code,created_at_ms,updated_at_ms,completed_at_ms FROM assistant_tasks LIMIT 0", operation: "validate_assistant_tasks")
        _ = try db.prepare("SELECT id,task_id,kind,text,created_at_ms FROM assistant_task_events LIMIT 0", operation: "validate_assistant_task_events")
        _ = try db.prepare("SELECT id,task_id,step_index,tool,args_json,decision,state,result_text,undo_json,undone_at_ms,created_at_ms FROM assistant_task_steps LIMIT 0", operation: "validate_assistant_task_steps")
        _ = try db.prepare("SELECT id,task_id,kind,payload_json,rpc_request_id,answer_json,created_at_ms,answered_at_ms FROM assistant_questions LIMIT 0", operation: "validate_assistant_questions")
        _ = try db.prepare("SELECT id,task_id,fire_at_ms,state,delivered_at_ms FROM assistant_reminders LIMIT 0", operation: "validate_assistant_reminders")
        _ = try db.prepare("SELECT id,task_id,kind,ref_id,source,title_snapshot,selected,sent_at_ms FROM assistant_materials LIMIT 0", operation: "validate_assistant_materials")
        _ = try db.prepare("SELECT chat_turn_token,chat_session_token,task_id,title_snapshot FROM assistant_task_links LIMIT 0", operation: "validate_assistant_task_links")
        _ = try db.prepare("SELECT chat_session_token,payload_json FROM assistant_composer_attachments LIMIT 0", operation: "validate_assistant_composer_attachments")
        for name in ["assistant_tasks_status", "assistant_tasks_chat_turn", "assistant_tasks_one_chat_turn",
                     "assistant_task_events_task", "assistant_task_steps_task", "assistant_reminders_due"] {
            guard try db.objectExists(type: "index", name: name) else { throw PersistenceError.invalidSchema(object: name) }
        }
    }
}

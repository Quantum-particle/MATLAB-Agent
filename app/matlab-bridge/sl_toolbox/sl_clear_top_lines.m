function result = sl_clear_top_lines(modelName)
% SL_CLEAR_TOP_LINES v11.6.7 — 安全清除模型顶层连线
%   仅删除模型顶层的信号线，子系统内部连线不受影响。
%
%   区别于 find_system(..., 'type','line') + FindAll='on' (递归)，
%   本函数使用 get_param(mn, 'Lines') 仅获取顶层连线。
%
%   输入:
%     modelName: char — 模型名称 (如 'Quadrotor_FDM')
%   输出:
%     result.status:  'ok' 或 'error'
%     result.cleared: double — 清除的连线数量
%     result.message: char — 错误信息 (仅 status='error')
%
%   用法示例:
%     result = sl_clear_top_lines('Quadrotor_FDM')
%     % → status: 'ok', cleared: 20

    try
        load_system(modelName);
        lines = get_param(modelName, 'Lines');
        count = length(lines);
        for i = 1:count
            try
                delete_line(lines(i));
            catch
                % 连线可能已被其他操作删除，忽略
            end
        end
        result.status = 'ok';
        result.cleared = count;
        result.message = sprintf('Cleared %d top-level line(s) from %s', count, modelName);
    catch ME
        result.status = 'error';
        result.cleared = 0;
        result.message = ME.message;
    end
end

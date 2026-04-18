function result = sl_delete_safe(blockPath, varargin)
% SL_DELETE_SAFE 安全删除模块 — 记录连线 + 可选级联删除悬空连线 + 验证删除
%   result = sl_delete_safe(blockPath)
%   result = sl_delete_safe(blockPath, 'cascade', true, ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   delete_block 行为（MathWorks 官方）:
%     - 自动删除与被删模块关联的所有连线
%     - 如果模块在子系统内，子系统端口不受影响
%     - 如果删的是子系统，子系统内所有模块和连线一并删除
%
%   输入:
%     blockPath        - 模块完整路径，如 'MyModel/Gain1'（必选）
%     'cascade'        - 是否级联删除悬空连线，默认 false
%                        true: 删除后检查并清理所有悬空连线
%                        false: 仅记录悬空连线信息，不主动删除
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%     'force'          - 强制删除（不检查是否被引用），默认 false
%
%   输出: struct
%     .status        - 'ok' 或 'error'
%     .deleted       - struct(.blockPath, .blockType, .connectedLines)
%     .orphanedLines - 悬空连线列表（cascade=false 时）
%     .cascadeResult - 级联删除结果（cascade=true 时）
%     .message       - 人类可读的总结信息
%     .error         - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'cascade', false, ...
        'loadModelIfNot', true, ...
        'force', false);

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'deleted', struct(), ...
        'orphanedLines', {{}}, 'cascadeResult', struct(), ...
        'message', '', 'error', '');

    % ===== 提取模型名 =====
    modelName = blockPath;
    slashIdx = strfind(blockPath, '/');
    if ~isempty(slashIdx)
        modelName = blockPath(1:slashIdx(1)-1);
    end

    % ===== 确保模型已加载 =====
    if opts.loadModelIfNot
        try
            if ~bdIsLoaded(modelName)
                load_system(modelName);
            end
        catch ME
            result.status = 'error';
            result.error = ['Model not loaded and cannot be loaded: ' ME.message];
            result.message = result.error;
            return;
        end
    end

    % ===== 验证模块存在 =====
    blockType = '';
    try
        blockType = get_param(blockPath, 'BlockType');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== 记录该模块的所有连线（删除前） =====
    connectedLines = {};
    try
        % 获取端口 handles
        ph = get_param(blockPath, 'PortHandles');
        
        % 输入端口连线
        if isfield(ph, 'Inport')
            for i = 1:length(ph.Inport)
                try
                    lineHandle = get_param(ph.Inport(i), 'Line');
                    if lineHandle ~= -1
                        lineInfo = get_line_info(modelName, lineHandle);
                        connectedLines{end+1} = lineInfo; %#ok<AGROW>
                    end
                catch
                end
            end
        end

        % 输出端口连线
        if isfield(ph, 'Outport')
            for i = 1:length(ph.Outport)
                try
                    lineHandle = get_param(ph.Outport(i), 'Line');
                    if lineHandle ~= -1
                        lineInfo = get_line_info(modelName, lineHandle);
                        connectedLines{end+1} = lineInfo; %#ok<AGROW>
                    end
                catch
                end
            end
        end

        % 启用/触发端口（如 Subsystem）
        if isfield(ph, 'Enable')
            for i = 1:length(ph.Enable)
                try
                    lineHandle = get_param(ph.Enable(i), 'Line');
                    if lineHandle ~= -1
                        lineInfo = get_line_info(modelName, lineHandle);
                        connectedLines{end+1} = lineInfo; %#ok<AGROW>
                    end
                catch
                end
            end
        end
        if isfield(ph, 'Trigger')
            for i = 1:length(ph.Trigger)
                try
                    lineHandle = get_param(ph.Trigger(i), 'Line');
                    if lineHandle ~= -1
                        lineInfo = get_line_info(modelName, lineHandle);
                        connectedLines{end+1} = lineInfo; %#ok<AGROW>
                    end
                catch
                end
            end
        end
    catch ME
        % PortHandles 获取失败，继续删除
    end

    result.deleted = struct('blockPath', blockPath, 'blockType', blockType, ...
        'connectedLines', connectedLines);

    % ===== 执行删除 =====
    try
        delete_block(blockPath);
    catch ME
        result.status = 'error';
        result.error = ['Failed to delete block: ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== 验证删除成功 =====
    try
        get_param(blockPath, 'BlockType');
        result.status = 'error';
        result.error = 'Block still exists after delete_block call';
        result.message = result.error;
        return;
    catch
        % 模块不存在 = 删除成功
    end

    % ===== 检查悬空连线 =====
    orphanedLines = {};
    try
        % 查找模型中所有连线
        lineHandles = find_system(modelName, 'SearchDepth', 1, ...
            'FindAll', 'on', 'Type', 'Line');
        
        for i = 1:length(lineHandles)
            try
                % 检查连线两端端口
                srcPort = get_param(lineHandles(i), 'SrcPortHandle');
                dstPort = get_param(lineHandles(i), 'DstPortHandle');
                
                % 悬空连线: 源端口或目标端口为 0（-1 表示未连接）
                if srcPort == 0 || dstPort == 0
                    linePath = get_param(lineHandles(i), 'Name');
                    if isempty(linePath)
                        linePath = ['Line_' num2str(lineHandles(i))];
                    end
                    orphanedLines{end+1} = struct('handle', lineHandles(i), ... %#ok<AGROW>
                        'name', linePath, ...
                        'srcPortHandle', srcPort, 'dstPortHandle', dstPort);
                end
            catch
                % 某些连线获取属性失败，跳过
            end
        end
    catch
        % find_system 失败，跳过悬空连线检查
    end

    result.orphanedLines = orphanedLines;

    % ===== 级联删除悬空连线 =====
    if opts.cascade && ~isempty(orphanedLines)
        cascadeDeleted = {};
        cascadeErrors = {};
        for i = 1:length(orphanedLines)
            try
                delete_line(modelName, orphanedLines{i}.handle);
                cascadeDeleted{end+1} = orphanedLines{i}.name; %#ok<AGROW>
            catch ME
                cascadeErrors{end+1} = ['Failed to delete: ' orphanedLines{i}.name ' - ' ME.message]; %#ok<AGROW>
            end
        end
        result.cascadeResult = struct('deleted', cascadeDeleted, 'errors', cascadeErrors);
        result.orphanedLines = {};  % 已级联删除，清空列表
    end

    % ===== 生成 message =====
    nLines = length(connectedLines);
    if opts.cascade && isfield(result.cascadeResult, 'deleted')
        nCascade = length(result.cascadeResult.deleted);
        result.message = sprintf('Deleted %s (%s), had %d connected lines, cascade deleted %d orphaned lines', ...
            blockPath, blockType, nLines, nCascade);
    else
        nOrphaned = length(orphanedLines);
        if nOrphaned > 0
            result.message = sprintf('Deleted %s (%s), had %d connected lines, %d orphaned lines remaining', ...
                blockPath, blockType, nLines, nOrphaned);
        else
            result.message = sprintf('Deleted %s (%s), had %d connected lines', ...
                blockPath, blockType, nLines);
        end
    end
end


% ===== 辅助函数: 获取连线信息 =====
function info = get_line_info(modelName, lineHandle)
    info = struct();
    try
        info.handle = lineHandle;
    catch
    end
    try
        info.name = get_param(lineHandle, 'Name');
    catch
        info.name = '';
    end
    try
        srcPort = get_param(lineHandle, 'SrcPortHandle');
        dstPort = get_param(lineHandle, 'DstPortHandle');
        info.srcPortHandle = srcPort;
        info.dstPortHandle = dstPort;
        
        % 获取源/目标模块名
        if srcPort ~= 0
            try
                srcBlock = get_param(srcPort, 'Parent');
                info.srcBlock = srcBlock;
            catch
                info.srcBlock = 'unknown';
            end
        end
        if dstPort ~= 0
            try
                dstBlock = get_param(dstPort, 'Parent');
                info.dstBlock = dstBlock;
            catch
                info.dstBlock = 'unknown';
            end
        end
    catch
    end
end

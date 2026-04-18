function jsonStr = sl_jsonencode(data)
% SL_JSONENCODE 兼容 R2016a+ 的 JSON 编码器
%   jsonStr = sl_jsonencode(data)
%
%   版本策略：高版本优先
%     R2016b+: 优先使用内置 jsonencode（性能更好，类型支持更全）
%     R2016a:   自动回退到自定义实现
%   自定义实现同时兼容 R2016a（用 [] 拼接，char(10) 替代 newline）。
%
%   支持类型: struct, cell, numeric, char, logical
%   高版本额外支持: string, datetime, table 等（由内置 jsonencode 处理）
%   不支持:   自定义对象（需先手动转为 struct）

    persistent useNative;
    if isempty(useNative)
        % R2016b+ 才有内置 jsonencode
        useNative = exist('jsonencode', 'file') == 2;
    end
    
    if useNative
        try
            jsonStr = jsonencode(data);
            return;
        catch
            % 内置 jsonencode 失败（如遇到不支持的对象类型），回退自定义实现
        end
    end
    
    jsonStr = custom_jsonencode(data);
end

function s = custom_jsonencode(data)
% 自定义 JSON 编码实现
% R2016a 兼容要点：
%   - 所有字符串拼接使用 [] 运算符（R2016a 不支持空格拼接 'a' 'b'）
%   - 使用 char(10) 替代 newline 关键字（R2016a 没有 newline）
%   - 使用预分配 cell(1,N) 替代 cell{end+1} 动态增长
%   - 不使用 string 类型（R2016a 没有 string）

    if isempty(data)
        s = '[]';
        return;
    end
    
    switch class(data)
        case 'struct'
            keys = fieldnames(data);
            if isempty(keys)
                s = '{}';
                return;
            end
            % 处理 struct 数组：每个元素生成独立 JSON 对象
            if length(keys) > 0 && numel(data) > 1
                items = cell(1, numel(data));
                for k = 1:numel(data)
                    elem = data(k);
                    elemKeys = fieldnames(elem);
                    pairs = cell(1, length(elemKeys));
                    for i = 1:length(elemKeys)
                        val = elem.(elemKeys{i});
                        pairs{i} = ['"' escape_json_str(elemKeys{i}) '":' custom_jsonencode(val)];
                    end
                    items{k} = ['{' strjoin(pairs, ',') '}'];
                end
                s = ['[' strjoin(items, ',') ']'];
            else
                pairs = cell(1, length(keys));
                for i = 1:length(keys)
                    val = data.(keys{i});
                    pairs{i} = ['"' escape_json_str(keys{i}) '":' custom_jsonencode(val)];
                end
                s = ['{' strjoin(pairs, ',') '}'];
            end
            
        case 'cell'
            if isempty(data)
                s = '[]';
                return;
            end
            items = cell(1, length(data));
            for i = 1:length(data)
                items{i} = custom_jsonencode(data{i});
            end
            s = ['[' strjoin(items, ',') ']'];
            
        case {'double','single','int8','int16','int32','int64', ...
              'uint8','uint16','uint32','uint64'}
            if isscalar(data)
                if isnan(data) || isinf(data)
                    s = 'null';
                else
                    s = num2str(data, 15);
                end
            else
                n = numel(data);
                items = cell(1, n);
                for i = 1:n
                    items{i} = custom_jsonencode(data(i));
                end
                s = ['[' strjoin(items, ',') ']'];
            end
            
        case 'logical'
            if isscalar(data)
                if data
                    s = 'true';
                else
                    s = 'false';
                end
            else
                n = numel(data);
                items = cell(1, n);
                for i = 1:n
                    if data(i)
                        items{i} = 'true';
                    else
                        items{i} = 'false';
                    end
                end
                s = ['[' strjoin(items, ',') ']'];
            end
            
        case 'char'
            s = ['"' escape_json_str(data) '"'];
            
        case 'string'
            % R2016b+ 才有 string 类型，但自定义实现也应处理
            s = ['"' escape_json_str(char(data)) '"'];
            
        otherwise
            % 尝试转为 struct 再编码
            try
                s = custom_jsonencode(struct(data));
            catch
                s = ['"' escape_json_str(class(data)) '"'];
            end
    end
end

function s = escape_json_str(str)
% JSON 字符串转义
% 注意：使用 char(10) 替代 newline（R2016a 没有 newline 关键字）
    s = strrep(str, '\', '\\');
    s = strrep(s, '"', '\"');
    s = strrep(s, char(10), '\n');       % LF — 兼容 R2016a
    s = strrep(s, char(13), '\r');       % CR
    s = strrep(s, char(9), '\t');        % TAB
end

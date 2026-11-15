function fluke_live_screen(source)
% FLUKE_LIVE_SCREEN  Fluke 190-504 Series II live USB display + controls.
%
%   fluke_live_screen                Auto-connect if one Fluke COM port is found; otherwise prompt
%   fluke_live_screen("COM11")       Connect directly without picker
%   fluke_live_screen("file.fbrle2d") Offline playback of one saved screen
%
% Buttons:
%   STOP/START ACQUISITION  Sends HO / AT to the Fluke (NOT just a PC pause).
%   SAVE IMAGE              Saves the last received 320 x 240 screen as PNG.
%   PAUSE/RESUME COMMUNICATION  Closes/reopens COM port so local keys work.
%   EXPORT ACTIVE CHANNELS  Queries QW 10/20/50/60, then saves a .mat
%                           file with one timetable per available channel.
%                           Uses real waveform samples, not LCD pixels.
%
% HOLD/RUN is read from the instrument at startup, before each toggle and
% before waveform export, and polled every ~2 seconds while displaying.
% Screen captures continue during HOLD so menus and settings stay visible.
% PAUSE COMMUNICATION instead stops ALL requests and releases the COM port;
% on resume the script reconnects, syncs the clock, and checks HOLD/RUN.
% The last captured LCD remains visible and can still be saved as PNG.
% HOLD freezes signal acquisition on the Fluke, not the MATLAB display.
% On connection, the instrument clock is set to Windows local date/time
% using WD and WT. The IS command provides charging/AC/battery-present
% indications but NOT the battery charge percentage.
%
% MATLAB R2019b+ / serialport; no add-on toolboxes required.
% Windows COM descriptions come from Windows PowerShell (CIM).
% Native screen protocol + 2D-RLE decoding verified with a Fluke 190-504
% Series II running firmware V11.46. Waveform-export code implements the
% documented QW protocol but has NOT yet been tested on the actual hardware.
%
% IMPORTANT:
%   - Close FlukeView and other users of the COM port before running.
%   - Commands are sent only BETWEEN complete screen transfers.
%   - A broken waveform/screen transfer stops the viewer; don't blindly retry
%     using the same connection. Power-cycle if synchronization is lost.
%   - The Fluke manual says QW can fail in Roll mode.
%
% Reference: Fluke 190 Remote Control and Programming Reference (2012),
% commands HO, AT, QP, QW and Appendix F (Waveform Data).

if nargin < 1 || isempty(source)
    source = pickCOMPort();
    if strlength(string(source)) == 0
        fprintf('COM port selection cancelled.\n');
        return
    end
end
source = string(source);
isOffline = endsWith(lower(source), ".fbrle2d");

s = [];                         % filled only in live mode
cleanup = [];                   % onCleanup owns the active serialport object
ident = "";                    % refreshed on every connection
commPaused = false;             % no QP, IS, or any USB traffic when true
isHeld = false;                % updated from Fluke IS status (bit 8 = 256)
holdStateKnown = false;        % no assumed acquisition state until IS succeeds
captureScreen = true;          % ALWAYS update the LCD, even during HOLD
pending = {};                  % deferred actions, never during USB transfer
closeRequested = false;
frameNo = 0;
lastRGB = [];                 % exact current LCD screenshot, RGB, 240x320x3
lastStamp = "";
lastTransferSec = NaN;
lastTransferBytes = NaN;
powerInfo = 'Power: not queried';
lastPowerPoll = tic;

fig = figure('Name','Fluke 190-504 - Live USB Screen', ...
    'NumberTitle','off', 'Color',[0.13 0.14 0.16], ...
    'Position',[150 150 920 755], 'MenuBar','none', ...
    'CloseRequestFcn',@onClose);
ax = axes('Parent',fig,'Units','normalized','Position',[0.027 0.16 0.946 0.79]);
h = image(ax,ones(240,320),'CDataMapping','direct');
colormap(ax,gray(192));
axis(ax,'image'); axis(ax,'off');
title(ax,'Waiting for screen ...','Color','w','FontWeight','normal');

btnHold = uicontrol('Parent',fig, 'Style','pushbutton', ...
    'Units','normalized','Position',[0.020 0.055 0.218 0.075], ...
    'String','Stop acquisition','FontSize',10,'FontWeight','bold', ...
    'Callback',@(~,~) enqueue('toggle'));
btnSave = uicontrol('Parent',fig, 'Style','pushbutton', ...
    'Units','normalized','Position',[0.250 0.055 0.208 0.075], ...
    'String','Save image (PNG)','FontSize',10, ...
    'Callback',@(~,~) enqueue('save'));
btnExport = uicontrol('Parent',fig, 'Style','pushbutton', ...
    'Units','normalized','Position',[0.470 0.055 0.278 0.075], ...
    'String','Export active channels (.mat)','FontSize',10, ...
    'Callback',@(~,~) enqueue('export'));
btnComm = uicontrol('Parent',fig, 'Style','pushbutton', ...
    'Units','normalized','Position',[0.760 0.055 0.220 0.075], ...
    'String','Pause communication','FontSize',10,'FontWeight','bold', ...
    'Callback',@(~,~) enqueue('comm'));
statusText = uicontrol('Parent',fig,'Style','text','Units','normalized', ...
    'Position',[0.03 0.007 0.63 0.033], ...
    'HorizontalAlignment','left','ForegroundColor',[0.86 0.87 0.9], ...
    'BackgroundColor',[0.13 0.14 0.16], ...
    'String','Connecting...','FontSize',9);
powerText = uicontrol('Parent',fig,'Style','text','Units','normalized', ...
    'Position',[0.66 0.007 0.31 0.033], ...
    'HorizontalAlignment','right','ForegroundColor',[0.92 0.93 0.96], ...
    'BackgroundColor',[0.13 0.14 0.16], ...
    'String','Power: ...','FontSize',9);
drawnow;

if isOffline
    set(btnHold,'Enable','off');
    set(btnExport,'Enable','off');
    set(btnComm,'Enable','off');
    fid = fopen(char(source),'rb');
    if fid < 0, error('Cannot open: %s',source); end
    raw = fread(fid,Inf,'*uint8');
    fclose(fid);
    [indices,palette,lastStamp] = decodeFBRLE2D(raw);
    showFrame(indices,palette);
    setStatus('Offline capture - Save image is available.');
    while isgraphics(fig) && ~closeRequested
        drawnow;
        if ~isempty(pending)
            action = pending{1}; pending(1) = [];
            if strcmp(action,'save'), saveImage(); end
        end
        pause(0.04);
    end
    return;
end

% Connect once at launch. The same helper is used when resuming after a
% manual communication pause, including clock sync and HOLD/RUN detection.
try
    connectScope();
catch ME
    disconnectScope();
    if isgraphics(fig), delete(fig); end
    rethrow(ME)
end

while isgraphics(fig) && ~closeRequested
    % Run a complete binary screen transfer without servicing callbacks.
    if ~commPaused && captureScreen
        t = tic;
        try
            raw = readNativeScreen(s);
            [indices,palette,lastStamp] = decodeFBRLE2D(raw);
            lastTransferSec = toc(t);
            lastTransferBytes = numel(raw);
        catch ME
            if isgraphics(fig)
                setStatus('Communication error - viewer stopped. See Command Window.');
            end
            warning('Fluke transfer failed: %s. Do not reuse an incomplete transfer.',ME.message);
            break
        end
        frameNo = frameNo + 1;
        if ~isgraphics(fig) || closeRequested, break; end
        showFrame(indices,palette);
        if ~isgraphics(fig) || closeRequested, break; end
        setStatus(sprintf('Frame %d | %.2f s (%.2f Hz) | %d bytes | %s', ...
            frameNo,lastTransferSec,1/max(lastTransferSec,eps), ...
            lastTransferBytes, acquisitionLabel()));
        captureScreen = true;  % QP continues during HOLD; menus/settings can change
    end

    % IS is only queried BETWEEN complete binary screen transfers.
    % Check every ~2 seconds in BOTH RUN and HOLD. The physical HOLD/RUN
    % button can be used at any time, and the GUI follows its real status.
    % This also keeps battery/power status updated while the screen refreshes.
    pollInterval = 2;
    if ~commPaused && ~any(strcmp(pending,'comm')) && toc(lastPowerPoll) >= pollInterval
        refreshPowerStatus();
    end

    % Callbacks only queue requests. Execute them here, when USB is idle.
    drawnow;
    while ~isempty(pending) && isgraphics(fig) && ~closeRequested
        action = pending{1};
        pending(1) = [];
        try
            switch action
                case 'comm'
                    if commPaused
                        resumeCommunication();
                    else
                        pauseCommunication();
                    end
                case 'toggle'
                    if commPaused
                        setStatus('Communication paused - resume before controlling acquisition.');
                        continue
                    end
                    % Read real scope state FIRST. The user may have pressed
                    % HOLD/RUN directly on the Fluke since the last poll.
                    flags = queryInstrumentStatus();
                    updateAcquisitionState(flags);
                    if isHeld
                        sendCmd(s,'AT'); checkAck(s,'AT');
                        setStatus('ARM TRIGGER (AT) sent.');
                    else
                        sendCmd(s,'HO'); checkAck(s,'HO');
                        setStatus('HOLD (HO) sent.');
                    end
                    % Re-read actual state rather than assuming AT always
                    % leaves the scope running (e.g. single-shot mode).
                    refreshPowerStatus();
                    captureScreen = true; % keep refreshing in both states
                case 'save'
                    saveImage();
                case 'export'
                    if commPaused
                        setStatus('Communication paused - resume before exporting channels.');
                        continue
                    end
                    exportChannels();
            end
        catch ME
            warning('Action "%s" failed: %s',action,ME.message);
            if isgraphics(fig)
                setStatus('Error: ' + string(ME.message));
            end
            % If a QW transfer has been interrupted, command parsing cannot
            % be trusted. Do not send another QP, AT, or QW on this port.
            if strcmp(action,'export') && isWaveformProtocolError(ME)
                closeRequested = true;
                break
            end
        end
        drawnow;
    end
    % No USB commands at all while paused. The GUI stays responsive, and
    % the cached image remains available to the Save Image button.
    if commPaused
        pause(0.05);
    end
end
% Close the active port explicitly. Its cleanup callback captures the port
% outside this function's workspace, avoiding the former onCleanup warning.
disconnectScope();
fprintf('Fluke viewer stopped; COM port released.\n');

    function connectScope()
        % The Series II virtual COM port ignores the baud-rate selection.
        % Always install independent cleanup immediately after opening.
        s = serialport(char(source),9600,'Timeout',35);
        cleanup = onCleanup(makeSerialCleanup(s));
        configureTerminator(s,'CR');
        flush(s);  % only once on a newly opened connection
        sendCmd(s,'ID');
        checkAck(s,'ID');
        ident = strtrim(string(readline(s)));
        fprintf('Connected: %s\n',ident);
        setStatus('Connected: ' + ident);
        syncClockFromPC(s);
        holdStateKnown = false; % physical keys may have changed it during pause
        lastPowerPoll = tic;
        refreshPowerStatus();
        if holdStateKnown
            fprintf('ScopeMeter acquisition at connection: %s\n', ...
                ternary(isHeld,'HOLD','RUN'));
        else
            warning('Acquisition state unknown; button will check IS before acting.');
        end
        setStatus('Connected to ' + source + ' - PC date/time synchronized.');
    end

    function disconnectScope()
        % The callback owns the port handle independently of the nested
        % 's' variable. Destroy it before clearing our serial reference.
        if ~isempty(cleanup)
            cleanup = []; % run onCleanup: delete(serialport) and release COM
        end
        s = [];
    end

    function pauseCommunication()
        % Called BETWEEN complete transfers, not while binary data is read.
        % Closing the virtual COM port is stronger than just stopping QP:
        % it allows the local ScopeMeter keyboard unrestricted use.
        commPaused = true;
        captureScreen = false;
        pending(strcmp(pending,'toggle') | strcmp(pending,'export')) = [];
        disconnectScope();
        if isgraphics(btnComm)
            set(btnComm,'String','Resume communication');
            set(btnHold,'Enable','off');
            set(btnExport,'Enable','off');
        end
        if isgraphics(powerText)
            set(powerText,'String','Power: not queried (paused)');
        end
        if isgraphics(ax)
            title(ax,sprintf('Fluke 190-504 | %s | COMMUNICATION PAUSED', ...
                char(lastStamp)),'Color','w','FontWeight','normal');
        end
        setStatus('Communication PAUSED - COM port released; use local Fluke buttons.');
        fprintf('Fluke USB communication paused; COM port released.\n');
    end

    function resumeCommunication()
        setStatus('Reconnecting to Fluke...');
        drawnow;
        try
            connectScope(); % also reads the true HOLD/RUN state again
        catch ME
            disconnectScope();
            commPaused = true;
            setStatus('Reconnection failed: ' + string(ME.message));
            rethrow(ME); % outer action handler warns; GUI remains paused
        end
        commPaused = false;
        captureScreen = true;
        if isgraphics(btnComm)
            set(btnComm,'String','Pause communication');
            set(btnHold,'Enable','on');
            set(btnExport,'Enable','on');
        end
        setStatus('Communication resumed - live screen and status updates active.');
        fprintf('Fluke USB communication resumed; screen refresh restarted.\n');
    end

    function enqueue(action)
        if ~closeRequested
            pending{end+1} = action;
        end
    end

    function onClose(~,~)
        closeRequested = true;
        if isgraphics(fig), delete(fig); end
    end

    function setStatus(message)
        if isgraphics(statusText)
            set(statusText,'String',char(string(message)));
        end
    end

    function flags = queryInstrumentStatus()
        % IS returns a decimal 16-bit mask. Bit 8 / value 256 = HOLD.
        % Read both ACK and status data, preserving protocol synchronization.
        sendCmd(s,'IS');
        checkAck(s,'IS');
        response = strtrim(char(readline(s)));
        bits = str2double(response);
        if ~isfinite(bits) || bits < 0 || bits > 65535 || bits ~= floor(bits)
            error('Unexpected IS reply: %s',response);
        end
        flags = uint16(bits);
    end

    function updateAcquisitionState(flags)
        % Do not infer HOLD from what the PC last commanded. The instrument
        % can independently change state through its physical HOLD/RUN key.
        actualHeld = bitand(flags,uint16(256)) ~= 0;
        changed = ~holdStateKnown || actualHeld ~= isHeld;
        isHeld = actualHeld;
        holdStateKnown = true;
        if isgraphics(btnHold)
            if isHeld
                set(btnHold,'String','Start acquisition');
            else
                set(btnHold,'String','Stop acquisition');
            end
        end
        if changed
            captureScreen = true; % always refresh, including changes during HOLD
        end
    end

    function name = acquisitionLabel()
        if ~holdStateKnown
            name = 'UNKNOWN';
        elseif isHeld
            name = 'HOLD';
        else
            name = 'RUN';
        end
    end

    function refreshPowerStatus()
        % A single IS query supplies HOLD/RUN plus charging/AC/battery.
        % Battery charge percentage is not available via this command.
        lastPowerPoll = tic;
        try
            flags = queryInstrumentStatus();
            updateAcquisitionState(flags);
            if bitand(flags,uint16(32)) == 0
                powerInfo = 'Battery: not detected';
            elseif bitand(flags,uint16(64)) ~= 0
                if bitand(flags,uint16(2)) ~= 0
                    powerInfo = 'Battery: charging (AC)';
                else
                    powerInfo = 'Battery: connected (AC)';
                end
            else
                powerInfo = 'Power: battery';
            end
        catch ME
            powerInfo = 'Battery: status unavailable';
            warning('Could not read Fluke IS status: %s',ME.message);
        end
        if isgraphics(powerText)
            set(powerText,'String',powerInfo);
        end
    end

    function showFrame(indices,palette)
        if ~isgraphics(h), return; end
        set(h,'CData',double(indices)+1);
        colormap(ax,palette);
        lastRGB = ind2rgb(double(indices)+1,palette);
        modeLabel = acquisitionLabel();
        title(ax,sprintf('Fluke 190-504 | %s | %s', ...
            char(lastStamp),modeLabel),'Color','w','FontWeight','normal');
        drawnow;
    end

    function saveImage()
        if isempty(lastRGB)
            setStatus('No screen available yet.');
            return
        end
        def = [datestr(now,'yyyymmdd_HHMMSS') '_Scopemeter_screen.png'];
        [filename,folder] = uiputfile({'*.png','PNG image (*.png)'}, ...
            'Save Scopemeter screen',def);
        if isequal(filename,0), return; end
        filename = fullfile(folder,filename);
        imwrite(lastRGB,filename,'png');
        fprintf('Saved Scopemeter screen: %s\n',filename);
        setStatus('Saved image: ' + string(filename));
    end

    function exportChannels()
        def = [datestr(now,'yyyymmdd_HHMMSS') '_Scopemeter_channels.mat'];
        [filename,folder] = uiputfile({'*.mat','MATLAB data (*.mat)'}, ...
            'Export active channels as timetables in a MAT-file',def);
        if isequal(filename,0), return; end
        filename = fullfile(folder,filename);
        if ~endsWith(lower(string(filename)),'.mat')
            filename = [filename '.mat'];
        end

        % Check the REAL hold state before export, including any physical
        % HOLD/RUN changes made since MATLAB last refreshed the status.
        flags = queryInstrumentStatus();
        updateAcquisitionState(flags);
        % Hold the instrument to acquire coherent A/B/C/D snapshots.
        % If the user already selected HOLD, leave it in HOLD afterwards.
        temporarilyHeld = false;
        if ~isHeld
            setStatus('Freezing acquisition before waveform export...');
            drawnow;
            sendCmd(s,'HO'); checkAck(s,'HO');
            temporarilyHeld = true;
        end

        codes = [10 20 50 60];
        channelNames = {'A','B','C','D'};
        waves = cell(1,4);
        errors = strings(1,4);
        transferInterrupted = false;
        try
            for k = 1:4
                setStatus(sprintf('Reading channel %s (QW %d)...', ...
                    channelNames{k},codes(k)));
                drawnow;
                [waves{k},reason] = queryWaveform(s,codes(k),channelNames{k});
                if isempty(waves{k})
                    errors(k) = reason;
                    fprintf('Channel %s skipped: %s\n',channelNames{k},reason);
                else
                    fprintf('Channel %s: %d time points, %s, %s\n', ...
                        channelNames{k},numel(waves{k}.t),waves{k}.kind,waves{k}.yUnit);
                end
            end
        catch ME
            transferInterrupted = true;
            % A read error might leave unread binary bytes on the serial
            % connection. Mark it so the outer loop stops rather than retries.
            wrapped = MException('Fluke:WaveformProtocol', ...
                'Waveform transfer interrupted: %s. Power-cycle if needed.',ME.message);
            if temporarilyHeld
                warning('Scope may remain in HOLD after incomplete waveform transfer.');
            end
            throw(wrapped);
        end

        if temporarilyHeld && ~transferInterrupted
            sendCmd(s,'AT'); checkAck(s,'AT');
            refreshPowerStatus(); % reflect actual post-export HOLD/RUN state
        end
        if ~any(~cellfun(@isempty,waves))
            error(['No channels returned waveform data. Ensure scope mode, ' ...
                   'active inputs and completed acquisition; Roll mode ' ...
                   'does not support QW.']);
        end
        writeWaveformMATFile(filename,waves,errors,ident);
        fprintf('Exported channels to: %s\n',filename);
        setStatus('Exported waveforms: ' + string(filename));
        captureScreen = true; % resume normal continuous LCD refresh after export
    end
end

function callback = makeSerialCleanup(port)
% Invoked OUTSIDE the viewer's nested-function scope. The returned callback
% captures 'port' here, not 's' in the viewer's exiting workspace.
    callback = @() releaseFlukeSerialPort(port);
end

function releaseFlukeSerialPort(port)
% Scope-independent cleanup callback. Never read nested workspace variables:
% the main fluke_live_screen workspace may already be exiting when called.
    try
        delete(port);
    catch
        % Suppress errors if MATLAB or a prior callback already closed it.
    end
end

function selectedPort = pickCOMPort()
% Windows device descriptions via CIM / PowerShell; fallback to COM name.
% serialportlist cannot return Device Manager friendly names by itself.
    selectedPort = "";
    ports = string(serialportlist('available'));
    ports = reshape(ports,1,[]);
    if isempty(ports)
        errordlg('No available COM ports were found. Connect the ScopeMeter and try again.', ...
                 'Fluke 190-504');
        return
    end

    labels = cellstr(ports);
    if ispc
        % Windows Device Manager port names (includes e.g. "Fluke USB Serial Port (COM11)").
        ps = ['powershell.exe -NoProfile -NonInteractive -Command "', ...
              'Get-CimInstance Win32_PnPEntity | ', ...
              'Where-Object { $_.Name -match ''\(COM[0-9]+\)'' } | ', ...
              'Select-Object -ExpandProperty Name"'];
        [ok,reply] = system(ps);
        if ok == 0
            devices = regexp(reply,'\r?\n','split');
            for j = 1:numel(devices)
                device = strtrim(devices{j});
                match = regexp(device,'\((COM[0-9]+)\)','tokens','once');
                if isempty(match), continue; end
                ix = find(strcmpi(ports,match{1}),1);
                if ~isempty(ix)
                    labels{ix} = device;
                end
            end
        end
    end

    % If exactly one available USB serial port belongs to Fluke, connect
    % automatically. If two or more Fluke devices are present, let the user
    % choose, and otherwise keep the original descriptive COM-port picker.
    names = string(labels);
    flukeMatches = find(contains(names,'Fluke USB Serial Port', ...
                                 'IgnoreCase',true));
    if isempty(flukeMatches)
        flukeMatches = find(contains(names,'Fluke','IgnoreCase',true));
    end
    if numel(flukeMatches) == 1
        selectedPort = ports(flukeMatches);
        fprintf('Auto-selected %s\n',labels{flukeMatches});
        return;
    end
    if isempty(flukeMatches)
        preferred = 1;
    else
        preferred = flukeMatches(1);
    end
    [chosen,confirmed] = listdlg( ...
        'Name','Fluke 190-504 - Select serial port', ...
        'PromptString','Select the ScopeMeter USB serial port:', ...
        'ListString',labels, ...
        'SelectionMode','single', ...
        'InitialValue',preferred, ...
        'ListSize',[530 270], ...
        'OKString','Connect', ...
        'CancelString','Cancel');
    if confirmed && ~isempty(chosen)
        selectedPort = ports(chosen);
    end
end

function syncClockFromPC(s)
% WD / WT: set ScopeMeter date and 24-hour time from local Windows clock.
% No UTC conversion is performed: the ScopeMeter holds local time.
    pcTime = datetime('now');
    dateCmd = sprintf('WD %d,%d,%d',year(pcTime),month(pcTime),day(pcTime));
    timeCmd = sprintf('WT %d,%d,%d',hour(pcTime),minute(pcTime),floor(second(pcTime)));
    sendCmd(s,dateCmd);
    checkAck(s,dateCmd);
    sendCmd(s,timeCmd);
    checkAck(s,timeCmd);
    fprintf('ScopeMeter clock set from PC: %s (local time)\n',datestr(pcTime,31));
end

function tf = isWaveformProtocolError(ME)
    tf = strcmp(ME.identifier,'Fluke:WaveformProtocol');
end

function str = ternary(condition,a,b)
    if condition, str = a; else, str = b; end
end

function [wave,reason] = queryWaveform(s,traceNo,channel)
% Query a scope-mode channel. ACK=2 is treated as no available trace;
% this also occurs if the instrument is in an incompatible mode.
    wave = [];
    reason = "";
    cmd = sprintf('QW %d',traceNo);
    sendCmd(s,cmd);
    ack = strtrim(string(readline(s)));
    if ack == "2"
        reason = "Fluke returned execution error (inactive/no trace or mode unsupported)";
        return
    end
    if ack ~= "0"
        error('Fluke ACK for %s = %s; stop rather than retry.',cmd,ack);
    end

    first = read(s,1,'uint8');
    if first == uint8(13)
        reason = "Empty waveform response";
        return
    end
    if first ~= uint8('#')
        error('QW %d: expected #0 admin block, got 0x%02X.',traceNo,first);
    end
    expectByte(s,uint8('0'),'admin block prefix');
    adminHeader = read(s,1,'uint8');
    % Fluke's Appendix F says 0x00 or 0x90, but its own QW example also
    % explicitly accepts 0x80 (decimal 128). The 190-504 V11.46 really
    % returns 0x80 when queried with QW 10. All three are valid variants.
    if ~ismember(double(adminHeader),[0 128 144])
        error('QW %d: unsupported admin header 0x%02X (expected 00/80/90).', ...
              traceNo,adminHeader);
    end
    adminLen = readBE(s,2);
    fprintf('QW %d: admin header 0x%02X, length %d bytes\n', ...
            traceNo,adminHeader,adminLen);
    if adminLen < 47 || adminLen > 2000
        error('QW %d: invalid admin length %d.',traceNo,adminLen);
    end
    adminData = reshape(read(s,adminLen,'uint8'),1,[]);
    checkBlockSum(s,adminData,'waveform admin');
    meta = parseWaveformAdmin(adminData);

    expectByte(s,uint8(','),'admin/sample separator');
    expectByte(s,uint8('#'),'samples block prefix');
    expectByte(s,uint8('0'),'samples block prefix');
    sampleHeader = read(s,1,'uint8');
    % Fluke Appendix F lists 129; its example program shows 144.
    % Accept either and validate the actual payload.
    if ~ismember(double(sampleHeader),[129 144])
        error('QW %d: unexpected samples block header 0x%02X.', ...
            traceNo,sampleHeader);
    end
    sampleLen = readBE(s,4);
    fprintf('QW %d: sample header 0x%02X, length %d bytes\n', ...
            traceNo,sampleHeader,sampleLen);
    if sampleLen < 6 || sampleLen > 5e6
        error('QW %d: invalid samples length %d.',traceNo,sampleLen);
    end
    sampleData = reshape(read(s,sampleLen,'uint8'),1,[]);
    checkBlockSum(s,sampleData,'waveform samples');
    expectByte(s,uint8(13),'QW reply terminator');

    wave = parseWaveformSamples(sampleData,meta);
    wave.channel = channel;
    wave.traceNo = traceNo;
end

function m = parseWaveformAdmin(b)
% Fixed 47-byte administration layout documented in Fluke Appendix F.
    p = 1;
    m.traceResult = double(b(p)); p = p+1;
    m.yUnitCode = double(b(p)); p = p+1;
    m.xUnitCode = double(b(p)); p = p+1;
    m.yDivisions = beValue(b(p:p+1)); p = p+2;
    m.xDivisions = beValue(b(p:p+1)); p = p+2;
    m.yScale = flukeFloat(b(p:p+2)); p = p+3;
    m.xScale = flukeFloat(b(p:p+2)); p = p+3;
    m.yStep = double(b(p)); p = p+1;
    m.xStep = double(b(p)); p = p+1;
    m.yZero = flukeFloat(b(p:p+2)); p = p+3;
    m.xZero = flukeFloat(b(p:p+2)); p = p+3;
    m.yResolution = flukeFloat(b(p:p+2)); p = p+3;
    m.xResolution = flukeFloat(b(p:p+2)); p = p+3;
    m.yAt0 = flukeFloat(b(p:p+2)); p = p+3;
    m.xAt0 = flukeFloat(b(p:p+2)); p = p+3;
    m.dateStamp = char(b(p:p+7)); p = p+8;
    m.timeStamp = char(b(p:p+5));
    m.yUnit = unitName(m.yUnitCode);
    m.xUnit = unitName(m.xUnitCode);
end

function wave = parseWaveformSamples(b,meta)
% Sample block is: format, three special sample values, count (uint16),
% then 1/2/3 values per point, with each value 1 or 2 bytes (big-endian).
    fmt = double(b(1));
    width = bitand(fmt,7);
    signed = bitand(fmt,128) ~= 0;
    modeBits = bitand(fmt,112);
    if ~ismember(width,[1 2])
        error('Unsupported Fluke sample width %d (format 0x%02X).',width,fmt);
    end
    switch modeBits
        case 0
            columns = 1; kind = 'normal';
        case {64,112}
            columns = 2; kind = 'minmax';
        case 96
            columns = 3; kind = 'minmaxavg';
        otherwise
            error('Unsupported Fluke sample format 0x%02X.',fmt);
    end
    p = 2;
    overload = readSampleValue(b(p:p+width-1),signed); p = p+width;
    underload = readSampleValue(b(p:p+width-1),signed); p = p+width;
    invalid = readSampleValue(b(p:p+width-1),signed); p = p+width;
    n = beValue(b(p:p+1)); p = p+2;
    if n < 1
        error('Waveform contains no samples.');
    end
    sampleBytes = b(p:end);
    expected = n*columns*width;
    if numel(sampleBytes) ~= expected
        error('Waveform sample size mismatch: %d bytes, expected %d.', ...
            numel(sampleBytes),expected);
    end
    if width == 1
        v = double(sampleBytes);
        if signed, v(v>=128)=v(v>=128)-256; end
    else
        two = reshape(double(sampleBytes),2,[]);
        v = two(1,:)*256 + two(2,:);
        if signed, v(v>=32768)=v(v>=32768)-65536; end
    end
    v = reshape(v,columns,n)';
    special = (v == overload) | (v == underload) | (v == invalid);
    v(special) = NaN;
    % Fluke's programming example uses raw*YResolution; YZero describes
    % the position of the zero code on the displayed grid, not an extra
    % offset to apply to these already calibrated sample values.
    values = v * meta.yResolution;

    wave = meta;
    wave.kind = kind;
    wave.format = fmt;
    wave.signed = signed;
    wave.sampleWidth = width;
    wave.nPoints = n;
    wave.overloadCode = overload;
    wave.underloadCode = underload;
    wave.invalidCode = invalid;
    wave.t = meta.xZero + (0:n-1)'*meta.xResolution;
    wave.values = values;
end

function writeWaveformMATFile(file,waves,reasons,instrumentID)
% Save a single MAT-file with one MATLAB timetable per active input.
% Each timetable has duration-valued row times and one or more signal
% columns. The associated waveform scaling and acquisition metadata are
% retained in timetable.Properties.UserData and Fluke.ChannelMetadata.
%
% Structure after loading:
%   Scopemeter.A                     Channel A timetable (when available)
%   Scopemeter.B                     Channel B timetable (when available)
%   Scopemeter.C                     Channel C timetable (when available)
%   Scopemeter.D                     Channel D timetable (when available)
%   Scopemeter.ChannelMetadata.A     Raw Fluke scaling, units and trace details
%   Scopemeter.Unavailable.A         Error reason if A was not exported
%
% Row times are acquisition-relative time, not wall-clock timestamps.
    Scopemeter = struct();
    Scopemeter.Instrument = char(instrumentID);
    Scopemeter.ExportedAtPC = datetime('now');
    Scopemeter.TimeReference = 'Scope acquisition time axis; not absolute PC time';
    Scopemeter.ActiveChannels = {};
    Scopemeter.ChannelMetadata = struct();
    Scopemeter.Unavailable = struct();

    channelNames = {'A','B','C','D'};
    for k = 1:4
        name = channelNames{k};
        w = waves{k};
        if isempty(w)
            Scopemeter.Unavailable.(name) = char(reasons(k));
            continue;
        end

        switch size(w.values,2)
            case 1
                variableNames = {'Signal'};
            case 2
                variableNames = {'Minimum','Maximum'};
            case 3
                variableNames = {'Minimum','Maximum','Average'};
            otherwise
                error('Channel %s has an unsupported waveform shape.',name);
        end

        % Use duration row times for compatibility with R2019b+.
        % The Fluke QW scope-mode X axis is an offset relative to trigger.
        switch lower(strtrim(w.xUnit))
            case 's'
                rowTimes = seconds(w.t(:));
            case 'h'
                rowTimes = hours(w.t(:));
            case 'days'
                rowTimes = days(w.t(:));
            otherwise
                error('Channel %s has unsupported time-axis unit "%s".', ...
                    name,w.xUnit);
        end

        tt = array2timetable(w.values, ...
            'RowTimes',rowTimes, ...
            'VariableNames',variableNames);
        tt.Properties.VariableUnits = repmat({w.yUnit},1,numel(variableNames));
        tt.Properties.Description = sprintf( ...
            'Fluke 190-504 channel %s, trace %d (%s)', ...
            name,w.traceNo,w.kind);

        % Avoid duplicating the potentially large waveform arrays in metadata.
        meta = rmfield(w,{'t','values'});
        meta.RowTimeUnit = 'duration';
        meta.TimeReference = 'Acquisition-relative; xZero included';
        tt.Properties.UserData = meta;

        Scopemeter.(name) = tt;
        Scopemeter.ChannelMetadata.(name) = meta;
        Scopemeter.ActiveChannels{end+1} = name; %#ok<AGROW>
    end

    % Write to the selected file, rather than generating an executable .m.
    save(file,'Scopemeter','-v7');
end

function checkBlockSum(s,b,context)
    sumOnWire = double(read(s,1,'uint8'));
    sumCalculated = mod(sum(double(b)),256);
    if sumOnWire ~= sumCalculated
        error('%s: checksum mismatch: got %d, expected %d.', ...
            context,sumOnWire,sumCalculated);
    end
end

function value = readBE(s,n)
    b = reshape(double(read(s,n,'uint8')),1,[]);
    value = beValue(b);
end

function value = beValue(b)
    value = 0;
    for j=1:numel(b), value = value*256 + double(b(j)); end
end

function value = readSampleValue(b,signed)
    value = beValue(b);
    if signed && value >= 2^(8*numel(b)-1)
        value = value - 2^(8*numel(b));
    end
end

function value = flukeFloat(b)
    mantissa = beValue(b(1:2));
    if mantissa>=32768, mantissa=mantissa-65536; end
    expo = double(b(3));
    if expo>=128, expo=expo-256; end
    value = mantissa*10^expo;
end

function label = unitName(n)
    labels = {'','V','A','Ohm','W','F','K','s','h','days','Hz', ...
              'deg','degC','degF','%','dBm50','dBm600','dBV','dBA', ...
              'dBW','VAR','VA'};
    if n >= 0 && n < numel(labels), label = labels{n+1};
    else, label = sprintf('unit%d',n); end
end

function expectByte(s,wanted,context)
    x = read(s,1,'uint8');
    if x ~= wanted
        error('Expected 0x%02X for %s; got 0x%02X.',wanted,context,x);
    end
end

function raw = readNativeScreen(s)
    sendCmd(s,'QP 0,12,B');
    checkAck(s,'QP 0,12,B');
    total = readAsciiLength(s);
    if total < 600 || total > 5e6
        error('Unexpected compressed screen length %d bytes.',total);
    end
    raw = zeros(total,1,'uint8');
    got = 0;
    last = false;
    for k=1:1024
        sendCmd(s,'0');
        checkAck(s,sprintf('segment %d',k));
        head = reshape(read(s,5,'uint8'),[],1);
        if numel(head)~=5 || head(1)~=35 || head(2)~=48
            error('Invalid binary segment header at segment %d.',k);
        end
        last = bitand(head(3),uint8(128))~=0;
        count = 256*double(head(4)) + double(head(5));
        if got+count > total
            error('Segment exceeds advertised screen length (%d).',total);
        end
        bytes = reshape(read(s,count,'uint8'),[],1);
        trailer = reshape(read(s,2,'uint8'),[],1);
        if numel(trailer)~=2 || trailer(2)~=13
            error('Invalid binary block trailer in segment %d.',k);
        end
        if mod(sum(double(bytes)),256) ~= double(trailer(1))
            error('Checksum mismatch in screen segment %d.',k);
        end
        raw(got+(1:count)) = bytes;
        got = got+count;
        if last, break; end
    end
    if ~last || got~=total
        error('Incomplete screen: received %d of %d bytes.',got,total);
    end
end

function [img,palette,stamp] = decodeFBRLE2D(raw)
% Verified 320x240 FBRLE2D native decoder (including inter-row refs).
    raw = reshape(uint8(raw),[],1);
    if numel(raw)<592 || ~isequal(raw(1:7)',uint8('FBRLE2D')) || raw(8)~=0
        error('Not a valid FBRLE2D payload.');
    end
    % FBRLE2D stores each palette triplet as B,G,R (NOT R,G,B).
    % Flipping the first/third components restores red channel A,
    % blue channel B and the original blue/yellow ScopeMeter menus.
    palette = reshape(double(raw(16:591)),3,192)'/255;
    palette = palette(:,[3 2 1]);
    year = 256*double(raw(9)) + double(raw(10));
    stamp = sprintf('%04d-%02d-%02d %02d:%02d:%02d', ...
        year,raw(11),raw(12),raw(13),raw(14),raw(15));
    np = 320*240;
    pixels = zeros(np,1,'uint8');
    p = 592; dest = 1;
    while p <= numel(raw)
        token = raw(p); p = p+1;
        idx = bitand(token,uint8(127));
        if bitand(token,uint8(128))~=0
            if p>numel(raw), error('Truncated RLE at byte %d.',p-1); end
            count = double(raw(p))+2; p = p+1;
        else
            count = 1;
        end
        if dest+count-1>np, error('FBRLE2D expanded past image size.'); end
        pixels(dest:dest+count-1)=idx;
        dest=dest+count;
    end
    if dest-1~=np, error('FBRLE2D expanded to %d pixels, expected %d.',dest-1,np); end
    img = reshape(pixels,320,240)';
    if any(img(1,:)>=126) || any(img(2,:)==126)
        error('FBRLE2D back-reference before source row.');
    end
    for row=2:240
        mask = img(row,:)==127;
        img(row,mask)=img(row-1,mask);
        if row>=3
            mask=img(row,:)==126;
            img(row,mask)=img(row-2,mask);
        end
    end
    if any(img(:)>=96), error('Invalid or unresolved FBRLE2D palette index.'); end
end

function sendCmd(s,cmd)
    write(s,uint8([double(char(cmd)) 13]),'uint8');
end

function checkAck(s,context)
    reply = strtrim(string(readline(s)));
    if reply ~= "0"
        error('Fluke ACK for %s = %s (0=OK, 1=syntax, 2=execution, 3=sync, 4=comm).', ...
            char(string(context)),char(reply));
    end
end

function n = readAsciiLength(s)
    digits = '';
    for i=1:20
        byte=read(s,1,'uint8');
        if byte==uint8(',')
            n=str2double(digits);
            if isempty(digits) || ~isfinite(n) || n<0 || fix(n)~=n
                error('Invalid length prefix "%s".',digits);
            end
            return;
        end
        if byte<uint8('0') || byte>uint8('9')
            error('Expected ASCII length, got 0x%02X.',byte);
        end
        digits(end+1)=char(byte); %#ok<AGROW>
    end
    error('Length prefix not terminated by comma.');
end

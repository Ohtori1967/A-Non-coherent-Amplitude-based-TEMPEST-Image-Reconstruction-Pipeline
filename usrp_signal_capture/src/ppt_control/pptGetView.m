function view = pptGetView()
%PPTGETVIEW Get current PowerPoint slide show view.
%   view = pptGetView() returns the SlideShowView object of the first
%   running PowerPoint slide show window.
%
%   Requirements:
%   - Windows
%   - PowerPoint is already running
%   - At least one slide show window is active

    try
        ppt = actxGetRunningServer('PowerPoint.Application');
    catch ME
        error('pptGetView:PowerPointNotRunning', ...
            'Cannot connect to PowerPoint. Make sure PowerPoint is running.\n%s', ...
            ME.message);
    end

    try
        if ppt.SlideShowWindows.Count < 1
            error('No active slide show window found.');
        end
        view = ppt.SlideShowWindows.Item(1).View;
    catch ME
        error('pptGetView:NoSlideShowWindow', ...
            'PowerPoint is running, but no active slide show window was found.\n%s', ...
            ME.message);
    end
end
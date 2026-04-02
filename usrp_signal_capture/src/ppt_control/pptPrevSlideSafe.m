function ok = pptPrevSlideSafe()
%PPTPREVSLIDESAFE Try to go to previous slide safely.
%   ok = pptPrevSlideSafe() returns true if successful, false otherwise.

    ok = false;
    try
        view = pptGetView();
        view.Previous;
        ok = true;
    catch ME
        warning('pptPrevSlideSafe:Failed', ...
            'Failed to go to previous PowerPoint slide: %s', ME.message);
    end
end
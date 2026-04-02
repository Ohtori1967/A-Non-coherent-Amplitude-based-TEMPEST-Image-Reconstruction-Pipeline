function ok = pptNextSlideSafe()
%PPTNEXTSLIDESAFE Try to advance to next slide without throwing fatal error.
%   ok = pptNextSlideSafe() returns true if successful, false otherwise.

    ok = false;
    try
        view = pptGetView();
        view.Next;
        ok = true;
    catch ME
        warning('pptNextSlideSafe:Failed', ...
            'Failed to advance PowerPoint slide: %s', ME.message);
    end
end
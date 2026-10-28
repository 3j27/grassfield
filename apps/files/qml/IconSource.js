.pragma library

// The image source of an icon name: a theme name goes to the synchronous theme provider on the GUI thread, an absolute path
// (an application's Icon= file) to the provider that decodes off the GUI thread (src/imageproviders.h: never mix them up).
function url(name) {
    return (name.startsWith("/") ? "image://appicon/" : "image://icon/") + name;
}

//-----------------------------------------------------------------------------
// typeinfo.h -- compatibility shim for modern MSVC (Visual Studio 2015+)
//
// Legacy Source code (VC6 .. VS2013) included the compiler header <typeinfo.h>.
// Microsoft removed <typeinfo.h> in VS2015; the standard header is <typeinfo>.
//
// src\public is on the include path for every project (see
// vpc_scripts\source_*_win32_*.vpc -> AdditionalIncludeDirectories), so this
// shim lets all of the old `#include <typeinfo.h>` / `"typeinfo.h"` sites
// resolve without editing each call site:
//   public/tier0/memalloc.h, game/server/physics_main.cpp,
//   game/client/particlemgr.h, game/client/c_baseentity.cpp,
//   game/client/physics_main_client.cpp, game/shared/predictioncopy*.cpp
//-----------------------------------------------------------------------------
#ifndef TYPEINFO_H
#define TYPEINFO_H
#ifdef _WIN32
#pragma once
#endif

#include <typeinfo>

// The old <typeinfo.h> exposed these in the global namespace (VC6 behavior).
// Harmless aliases for code that names them without std::.
using std::type_info;
using std::bad_cast;
using std::bad_typeid;

#endif // TYPEINFO_H

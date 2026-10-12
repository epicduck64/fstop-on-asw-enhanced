//========= Copyright � 1996-2005, Valve Corporation, All rights reserved. ============//
//
// Purpose: 
//
// $Workfile:     $
// $NoKeywords: $
//=============================================================================//
#ifndef C_JIGGLEBONES_H
#define C_JIGGLEBONES_H

#ifdef _WIN32
#pragma once
#endif

#include "studio.h"
#include "UtlVector.h"
#include "utllinkedlist.h"

//-----------------------------------------------------------------------------
/**
 * JiggleData is the instance-specific data for a jiggle bone
 */
struct JiggleData
{
	void Init( int initBone, float currenttime, const Vector &initBasePos, const Vector &initTipPos )
	{
		bone = initBone;

		lastUpdate = currenttime;

		basePos = initBasePos;
		baseLastPos = basePos;
		baseVel.Init();
		baseAccel.Init();

		tipPos = initTipPos;
		tipVel.Init();
		tipAccel.Init();
	}

	int bone;
	int id;

	float lastUpdate;	// based on gpGlobals->realtime

	Vector basePos;		// position of the base of the jiggle bone
	Vector baseLastPos;
	Vector baseVel;
	Vector baseAccel;

	Vector tipPos;		// position of the tip of the jiggle bone
	Vector tipVel;
	Vector tipAccel;
};

class CJiggleBones
{
public:
	CJiggleBones() : m_pDebugModelName( NULL ), m_nDebugEntIndex( -1 ) {}

	JiggleData * GetJiggleData( int bone, float currenttime, const Vector &initBasePos, const Vector &initTipPos );
	void BuildJiggleTransformations( int boneIndex, float currentime, const mstudiojigglebone_t *jiggleParams, const matrix3x4_t &goalMX, matrix3x4_t &boneMX );

	// TEMPORARY diagnostic: identifies the owner of a sim whose state has gone
	// non-finite, so the "tipPos/tipVel NaN" warnings can be traced to a model.
	// Set once by C_BaseAnimating when it creates the sim.
	const char	*m_pDebugModelName;
	int			 m_nDebugEntIndex;

	CUtlLinkedList< JiggleData >	m_jiggleBoneState;
};


extern void DevMsgRT( char const* pMsg, ... );

#endif // C_BASEANIMATING_H

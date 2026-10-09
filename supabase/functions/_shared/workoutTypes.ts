// Workout-mode catalogue (contracts/workout-types-1.json; docs/context-watchdog/WORKOUTS.md). Every layer mirrors that
// file: Swift WorkoutTypeCatalog.swift, SQL public.workout_types (20261009170000_user_workouts.sql) and this table.
// tests/workout_types_parity_test.ts fails when this table or the SQL seed drifts from the JSON; edit the JSON first.

export const WORKOUT_TYPES_VERSION = 'workout-types-1';

export interface WorkoutType {
  id: string;
  name: string;
  sport_name: string;
  decoder_kind: 'running' | 'walking' | 'cycling' | 'other';
  environment: 'indoor' | 'outdoor' | 'either';
  locomotion: 'walking' | 'running' | 'cycling' | 'none' | 'mixed';
  effort: 'light' | 'moderate' | 'vigorous' | 'resistance';
  gait_expected: boolean;
  arm_motion: 'swing' | 'fixed' | 'varied';
  steps_expected: boolean;
  sport_aliases: readonly string[];
}

export const WORKOUT_TYPES: readonly WorkoutType[] = [
  { id: 'strength', name: 'Strength training', sport_name: 'Strength', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'resistance', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: ['Weightlifting', 'Bodybuilding', 'Powerlifting', 'Calisthenics'] },
  { id: 'hiit', name: 'HIIT / circuit', sport_name: 'HIIT', decoder_kind: 'other',
    environment: 'either', locomotion: 'mixed', effort: 'vigorous', gait_expected: false,
    arm_motion: 'varied', steps_expected: true, sport_aliases: ['CrossFit', 'Boot camp', 'Jump rope'] },
  { id: 'indoor_walk', name: 'Indoor walk (treadmill)', sport_name: 'Treadmill walk', decoder_kind: 'walking',
    environment: 'indoor', locomotion: 'walking', effort: 'moderate', gait_expected: true,
    arm_motion: 'varied', steps_expected: true, sport_aliases: [] },
  { id: 'outdoor_walk', name: 'Outdoor walk', sport_name: 'Walking', decoder_kind: 'walking',
    environment: 'outdoor', locomotion: 'walking', effort: 'moderate', gait_expected: true,
    arm_motion: 'swing', steps_expected: true, sport_aliases: ['Nordic walking', 'Rucking'] },
  { id: 'indoor_run', name: 'Indoor run (treadmill)', sport_name: 'Treadmill run', decoder_kind: 'running',
    environment: 'indoor', locomotion: 'running', effort: 'vigorous', gait_expected: true,
    arm_motion: 'varied', steps_expected: true, sport_aliases: [] },
  { id: 'outdoor_run', name: 'Outdoor run', sport_name: 'Running', decoder_kind: 'running',
    environment: 'outdoor', locomotion: 'running', effort: 'vigorous', gait_expected: true,
    arm_motion: 'swing', steps_expected: true, sport_aliases: [] },
  { id: 'indoor_cycling', name: 'Indoor cycling', sport_name: 'Indoor cycle', decoder_kind: 'cycling',
    environment: 'indoor', locomotion: 'cycling', effort: 'moderate', gait_expected: false,
    arm_motion: 'fixed', steps_expected: false, sport_aliases: ['Spinning'] },
  { id: 'outdoor_cycling', name: 'Outdoor cycling', sport_name: 'Cycling', decoder_kind: 'cycling',
    environment: 'outdoor', locomotion: 'cycling', effort: 'moderate', gait_expected: false,
    arm_motion: 'fixed', steps_expected: false, sport_aliases: ['Mountain biking'] },
  { id: 'rowing', name: 'Rowing / erg', sport_name: 'Row machine', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'vigorous', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: ['Rowing', 'Kayaking'] },
  { id: 'elliptical', name: 'Elliptical', sport_name: 'Elliptical', decoder_kind: 'other',
    environment: 'indoor', locomotion: 'none', effort: 'moderate', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: [] },
  { id: 'stair_climber', name: 'Stair climber', sport_name: 'Stair climber', decoder_kind: 'other',
    environment: 'indoor', locomotion: 'walking', effort: 'vigorous', gait_expected: true,
    arm_motion: 'varied', steps_expected: true, sport_aliases: [] },
  { id: 'swimming', name: 'Swimming', sport_name: 'Pool swim', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'vigorous', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: ['Open-water swim'] },
  { id: 'yoga', name: 'Yoga', sport_name: 'Yoga', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'light', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: [] },
  { id: 'pilates', name: 'Pilates', sport_name: 'Pilates', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'moderate', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: [] },
  { id: 'stretching', name: 'Stretching / mobility', sport_name: 'Stretching', decoder_kind: 'other',
    environment: 'either', locomotion: 'none', effort: 'light', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: [] },
  { id: 'sports', name: 'Sports (team / racket)', sport_name: 'Sports', decoder_kind: 'other',
    environment: 'either', locomotion: 'mixed', effort: 'vigorous', gait_expected: true,
    arm_motion: 'varied', steps_expected: true, sport_aliases: ['Tennis', 'Padel', 'Pickleball', 'Squash', 'Badminton', 'Racquetball', 'Table tennis', 'Basketball', 'Soccer', 'Volleyball', 'Baseball', 'Softball', 'Ice Hockey', 'Rugby', 'Cricket', 'Handball', 'Netball', 'Lacrosse', 'Field hockey', 'American football', 'Australian football', 'Gaelic football'] },
  { id: 'hiking', name: 'Hiking', sport_name: 'Hiking', decoder_kind: 'walking',
    environment: 'outdoor', locomotion: 'walking', effort: 'moderate', gait_expected: true,
    arm_motion: 'swing', steps_expected: true, sport_aliases: [] },
  { id: 'dance', name: 'Dance', sport_name: 'Dancing', decoder_kind: 'other',
    environment: 'either', locomotion: 'mixed', effort: 'moderate', gait_expected: false,
    arm_motion: 'varied', steps_expected: true, sport_aliases: ['Ballet', 'Breakdancing'] },
  { id: 'martial_arts', name: 'Martial arts / boxing', sport_name: 'Martial arts', decoder_kind: 'other',
    environment: 'either', locomotion: 'mixed', effort: 'vigorous', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: ['Boxing', 'Kickboxing', 'Jiu jitsu', 'Judo', 'Muay Thai', 'Fencing'] },
  { id: 'other', name: 'Other', sport_name: 'Other', decoder_kind: 'other',
    environment: 'either', locomotion: 'mixed', effort: 'moderate', gait_expected: false,
    arm_motion: 'varied', steps_expected: false, sport_aliases: [] },
];

const BY_ID = new Map(WORKOUT_TYPES.map((t) => [t.id, t]));

/** The catalogue type with this id, or undefined (an own-property lookup: `constructor` is not a type). */
export function workoutType(id: unknown): WorkoutType | undefined {
  return typeof id === 'string' ? BY_ID.get(id) : undefined;
}

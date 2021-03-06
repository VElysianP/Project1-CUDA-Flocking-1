#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 512

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

//************My own pointers here ********************
int* devGridCellnumber;
int* devBoidIndex;
thrust::device_ptr<int> dev_thrust_girdCellNumber;
thrust::device_ptr<int> dev_boidIndex;

//the pointer for GPU the check whether the grid cell has any boids
//and stores the start index of the boids if there are boids inside 
int* gridCellIndex;

//End of my own pointers 

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;




/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.

  //for(int i = 0;i < (gridSideCount*gridSideCount*gridSideCount);i++
  //{
	 // gridCellIndex[i] = -1;
  //}

  cudaMalloc((void**)&devGridCellnumber, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc devGridCellnumber failed!");

  cudaMalloc((void**)&devBoidIndex, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc devBoidIndex failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc gridStartIndecies failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc gridEndIndecies failed!");

  cudaMalloc((void**)&gridCellIndex, gridSideCount*gridSideCount*gridSideCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc gridCellIndex failed!");

  cudaThreadSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO <<<fullBlocksPerGrid, blockSize >>>(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO <<<fullBlocksPerGrid, blockSize >>>(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}


/******************
* stepSimulation *
******************/

__device__ float BoidDistanceCalculation(glm::vec3 pos1, glm::vec3 pos2)
{
	return glm::length(pos1 - pos2);
}

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
//use dev_vel1 to store the velocity of last dt, and update it to dev_vel2, then update dev_pos, and finally store the 
//data of dev_vel2 into dev_vel1
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
	if (iSelf >= N)
	{
		return;
	}

	//put this variable into the register 
	glm::vec3 thisPos = pos[iSelf];
	glm::vec3 originalSpeed = vel[iSelf];

	// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
	glm::vec3 perceivedCenter = glm::vec3(0.f);
	int count1 = 0;

	for (int i = 0;i < N;i++)
	{
		if (i != iSelf)
		{
			glm::vec3 testPos1 = pos[i];
			if (BoidDistanceCalculation(testPos1,thisPos)< rule1Distance)
			{
				perceivedCenter += testPos1;
				count1++;
			}
		}	
	}
	if (count1 != 0)
	{
		perceivedCenter /= count1;
	}
	else
	{
		perceivedCenter = thisPos;
	}

	//perceivedCenter = glm::vec3(-50.0, -50.0, -50.0);

  // Rule 2: boids try to stay a distance d away from each other

	glm::vec3 cVector = glm::vec3(0.0f);
	for (int j = 0;j < N;j++)
	{
		if (j != iSelf)
		{
			glm::vec3 testPos2 = pos[j];
			if (BoidDistanceCalculation(testPos2,thisPos) < rule2Distance)
			{
				if (BoidDistanceCalculation(testPos2, thisPos)< 100.f)
				{
					cVector -= (testPos2 - thisPos);
				}
			}
		}	
	}

  // Rule 3: boids try to match the speed of surrounding boids
	glm::vec3 perceivedVelocity = glm::vec3(0.0f);
	int count2 = 0;
	for (int k = 0;k < N;k++)
	{
		if (k != iSelf)
		{
			glm::vec3 testPos3 = pos[k];
			glm::vec3 testVel3 = vel[k];
			if (BoidDistanceCalculation(testPos3, thisPos) < rule3Distance)
			{
				perceivedVelocity += testVel3;
				count2++;
			}
		}
	}
	if (count2 != 0)
	{
		perceivedVelocity /= count2;
	}

	originalSpeed = originalSpeed + (perceivedCenter - thisPos)*rule1Scale + cVector*rule2Scale + perceivedVelocity*rule3Scale;

	return originalSpeed;
	//return glm::vec3(0.1,0.2,1.0);
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
	int indexNumber = threadIdx.x + (blockIdx.x * blockDim.x);

	if (indexNumber >= N) {
		return;
	}

  // Compute a new velocity based on pos and vel1
	glm::vec3 updatedVel = computeVelocityChange(N, indexNumber, pos, vel1);
	//I think we should wait untill all the thread have their updated speed 
	//and then uppdate them into dev_vel2

  // Clamp the speed
	if (glm::length(updatedVel) > maxSpeed)
	{
		updatedVel = glm::normalize(updatedVel)*maxSpeed;
	}
		//updatedVel = glm::clamp(updatedVel, -maxSpeed, maxSpeed);
    vel2[indexNumber] = updatedVel;


  // Record the new velocity into vel2. Question: why NOT vel1?
	//Also I think all the threads should wait until all the threads updated their speed 
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
  //I add up this sync because I think we should wait until all the threads have their new positions
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
	if ((x >= gridResolution) || (x < 0) || (y >= gridResolution) || (y < 0) || (z >= gridResolution) || (z < 0))
	{
		return -1;
	}
	else
	{
		return x + y * gridResolution + z * gridResolution * gridResolution;
	}
 
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}

	indices[index] = index;
	glm::vec3 boidPosition = pos[index];
	int xIdx = floor((boidPosition.x - gridMin.x)*inverseCellWidth);
	int yIdx = floor((boidPosition.y - gridMin.y)*inverseCellWidth);
	int zIdx = floor((boidPosition.z - gridMin.z)*inverseCellWidth);

	int gridIdx = gridIndex3Dto1D(xIdx, yIdx, zIdx, gridResolution);
	gridIndices[index] = gridIdx;
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

//As for my method, I think this is a very bad way
//I don't think it is really efficient to put so many branches into this kernel 
//Whereas I think it is super inefficient, I think I need better way.
__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"

	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N)
	{
		return;
	}

	if (index == 0)
	{
		gridCellStartIndices[index] = index;
		if (particleGridIndices[index] != particleGridIndices[index + 1])
		{
			gridCellEndIndices[index] = index;
		}
		else
		{
			int i = index;
			while (particleGridIndices[i] == particleGridIndices[i + 1])
			{
				i++;
			}
			gridCellEndIndices[index] = i + 1;
		}
		return;
	}

	if (index == N - 1)
	{
		gridCellEndIndices[index] = index;
		if (particleGridIndices[index - 1] != particleGridIndices[index])
		{
			gridCellStartIndices[index] = index;
		}
		else
		{
			int j = index;
			while (particleGridIndices[j - 1] == particleGridIndices[j])
			{
				j--;
			}
			gridCellStartIndices[index] = j - 1;
		}
		return;
	}

	//others
	if (particleGridIndices[index - 1] != particleGridIndices[index])
	{
		gridCellStartIndices[index] = index;
	}
	else
	{
		int k = index;
		while (particleGridIndices[k - 1] == particleGridIndices[k])
		{
			k--;
		}
		gridCellStartIndices[index] = k - 1;
	}

	if (particleGridIndices[index] != particleGridIndices[index + 1])
	{
		gridCellEndIndices[index] = index;
	}
	else
	{
		int p = index;
		while (particleGridIndices[p] == particleGridIndices[p + 1])
		{
			p++;
		}
		gridCellEndIndices[index] = p + 1;
	}
	return;
}

//__device__  glm::vec3 gridIndex1Dto3D(int gridIndex, int gridResolution)
//{
//	int zIdx = (int)gridIndex / (gridResolution*gridResolution);
//	int yIdx = (int)((gridIndex - zIdx*gridResolution*gridResolution)/gridResolution);
//	int xIdx = gridIndex - zIdx*gridResolution*gridResolution - yIdx*gridResolution;
//	glm::vec3 gridIndex3D = glm::vec3(xIdx, yIdx, zIdx);
//	return gridIndex3D;
//}


//for each grid, we calculate the start index 
__global__ void renewGridCellIndex(int N, int *gridCellStartIndices,int* gridCellIndex, int* particleGridIndices)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N)
	{
		return;
	}
	int gridNumber = particleGridIndices[index];
	int startIndex = gridCellStartIndices[index];

    gridCellIndex[gridNumber] = startIndex;

}


__device__ glm::vec3 newUpdateVelocity(int N,int index,int boidIndex, const glm::vec3 *pos, const glm::vec3 *vel, const int *particleArrayIndices,
const int* particleGridIndices, int *gridCellStartIndices, int *gridCellEndIndices, int * gridCellIndex,int gridSideCount, int gridCellWidth)
{
	glm::vec3 currentPosition = pos[boidIndex];
	glm::vec3 currentVelocity = vel[boidIndex];

	int gridIndex = particleGridIndices[index];
	int gridIdx3Z = (int)gridIndex / (gridSideCount*gridSideCount);
	int gridIdx3Y = (int)((gridIndex - gridIdx3Z*gridSideCount*gridSideCount) / gridSideCount);
	int gridIdx3X = gridIndex - gridIdx3Z*gridSideCount*gridSideCount - gridIdx3Y*gridSideCount;
	//glm::vec3 gridIndex3D = gridIndex1Dto3D(gridIndex, gridSideCount);

	int startIndex = gridCellStartIndices[index];
	int endIndex = gridCellEndIndices[index];

	glm::vec3 perceivedCenter = glm::vec3(0.0f);
	int count1 = 0;
	glm::vec3 vectorC = glm::vec3(0.0f);
	glm::vec3 perceivedVelocity = glm::vec3(0.f);
	int count3 = 0;

	//add up the speed of boids in the same grid
	for (int i = startIndex;i <= endIndex;i++)
	{
		if (i != index)
		{
			int tempBoidIndex = particleArrayIndices[i];
			glm::vec3 testPosition = pos[tempBoidIndex];
			glm::vec3 testVelocity = vel[tempBoidIndex];
			//rule1
			if (glm::length(testPosition - currentPosition) < rule1Distance)
			{
				perceivedCenter += testPosition;
				count1++;
			}
			
			//rule2
			if (glm::length(testPosition - currentPosition) < rule2Distance)
			{
				if (glm::length(testPosition - currentPosition) < 100.f)
				{
					vectorC -= (testPosition - currentPosition);
				}
			}

			//rule3
			if (glm::length(testPosition - currentPosition) < rule3Distance)
			{
				perceivedVelocity += testVelocity;
				count3++;
			}
		}		
	}

	//test the neighboring grid cells 
	for (int j = (gridIdx3X - 1);j <= (gridIdx3X + 1);j++)
	{
		for (int k = (gridIdx3Y - 1);k <= (gridIdx3Y + 1);k++)
		{
			for (int m = (gridIdx3Z - 1);m <= gridIdx3Z + 1;m++)
			{
				//if 3D to 1D is -1 means the grid we are testing does not have 8 neighbors 
				int testGridIndexBeighbor = gridIndex3Dto1D(j, k, m, gridSideCount);
				if (testGridIndexBeighbor != -1)
				{
					//not the gridItself
					if (testGridIndexBeighbor != gridIndex)
					{
						//equals to -1 means there are not boids inside this grid cell
						if (gridCellIndex[testGridIndexBeighbor] != -1)
						{
							int startPoint = gridCellIndex[testGridIndexBeighbor];
							int endPoint = gridCellEndIndices[startPoint];
							for (int n = startPoint;n <= endPoint;n++)
							{
								int testBoidIndex = particleArrayIndices[n];
								glm::vec3 testPos = pos[testBoidIndex];
								glm::vec3 testVel = vel[testBoidIndex];

								//rule1
								if (glm::length(testPos - currentPosition) < rule1Distance)
								{
									perceivedCenter += testPos;
									count1++;
								}

								//rule2
								if (glm::length(testPos - currentPosition) < rule2Distance)
								{
									if (glm::length(testPos - currentPosition) < 100.f)
									{
										vectorC -= (testPos - currentPosition);
									}
								}

								//rule3
								if (glm::length(testPos - currentPosition) < rule3Distance)
								{
									perceivedVelocity += testVel;
									count3++;
								}
							}
						}
					}
				}
			}
		}
	}

	
	//add up the speed of adjcent grids
	if (count1 == 0)
	{
		perceivedCenter = currentPosition;
	}
	else
	{
		perceivedCenter /= count1;
	}

	if (count3 != 0)
	{
		perceivedVelocity /= count3;
	}
	glm::vec3 finalSpeed = currentVelocity + (perceivedCenter - currentPosition)*rule1Scale + vectorC*rule2Scale + perceivedVelocity*rule3Scale;
	return finalSpeed;
}


__device__ glm::vec3 UpdateVelocity8Grids(int N, int index, int boidIndex, const glm::vec3 *pos, const glm::vec3 *vel, const int *particleArrayIndices,
	const int* particleGridIndices, int *gridCellStartIndices, int *gridCellEndIndices, int * gridCellIndex, int gridSideCount, int gridCellWidth,glm::vec3 gridMin)
{
	glm::vec3 currentPosition = pos[boidIndex];
	glm::vec3 currentVelocity = vel[boidIndex];

	int gridIndex = particleGridIndices[index];
	int gridIdx3Z = (int)gridIndex / (gridSideCount*gridSideCount);
	int gridIdx3Y = (int)((gridIndex - gridIdx3Z*gridSideCount*gridSideCount) / gridSideCount);
	int gridIdx3X = gridIndex - gridIdx3Z*gridSideCount*gridSideCount - gridIdx3Y*gridSideCount;


	int startIndex = gridCellStartIndices[index];
	int endIndex = gridCellEndIndices[index];

	glm::vec3 perceivedCenter = glm::vec3(0.0f);
	int count1 = 0;
	glm::vec3 vectorC = glm::vec3(0.0f);
	glm::vec3 perceivedVelocity = glm::vec3(0.f);
	int count3 = 0;

	glm::vec3 gridCenterPos = gridMin + glm::vec3(gridIdx3X*gridCellWidth + gridCellWidth*0.5, gridIdx3Y*gridCellWidth + gridCellWidth*0.5, gridIdx3Z*gridCellWidth + gridCellWidth*0.5);

	glm::vec3 disPos = currentPosition - gridCenterPos;

	int xStart, yStart, zStart;
	int xEnd, yEnd, zEnd;
	if ((float)disPos.x ==0.0)
	{
		xStart = gridIdx3X;
		xEnd = gridIdx3X;
	}
	else if (disPos.x > 0)
	{
		xStart = gridIdx3X;
		xEnd = gridIdx3X + 1;
	}
	else
	{
		xStart = gridIdx3X-1;
		xEnd = gridIdx3X;
	}

	if ((float)disPos.y == 0.0)
	{
		yStart = gridIdx3Y;
		yEnd = gridIdx3Y;
	}
	else if (disPos.y > 0)
	{
		yStart = gridIdx3Y;
		yEnd = gridIdx3Y + 1;
	}
	else
	{
		yStart = gridIdx3Y - 1;
		yEnd = gridIdx3Y;
	}

	if ((float)disPos.z == 0.0)
	{
		zStart = gridIdx3Z;
		zEnd = gridIdx3Z;
	}
	else if (disPos.z > 0)
	{
		zStart = gridIdx3Z;
		zEnd = gridIdx3Z + 1;
	}
	else
	{
		zStart = gridIdx3Z - 1;
		zEnd = gridIdx3Z;
	}

	for (int i = xStart;i <= xEnd;i++)
	{
		for (int j = yStart;j <= yEnd;j++)
		{
			for (int k = zStart;k <= zEnd;k++)
			{
				int testGridIndexBeighbor = gridIndex3Dto1D(i, j, k, gridSideCount);
				if (testGridIndexBeighbor != -1)
				{
					int gridBoidStartIndex = gridCellIndex[testGridIndexBeighbor]; 
					if (gridBoidStartIndex != -1)
					{
						//int startIndex = gridCellStartIndices[gridBoidStartIndex];
						int endIndex = gridCellEndIndices[gridBoidStartIndex];
						for (int l = gridBoidStartIndex;l <= endIndex;l++)
						{
							int testBoidIndex = particleArrayIndices[l];
							glm::vec3 testPos = pos[testBoidIndex];
							glm::vec3 testVel = vel[testBoidIndex];

							//rule1
							if (glm::length(testPos - currentPosition) < rule1Distance)
							{
								perceivedCenter += testPos;
								count1++;
							}

							//rule2
							if (glm::length(testPos - currentPosition) < rule2Distance)
							{
								if (glm::length(testPos - currentPosition) < 100.f)
								{
									vectorC -= (testPos - currentPosition);
								}
							}

							//rule3
							if (glm::length(testPos - currentPosition) < rule3Distance)
							{
								perceivedVelocity += testVel;
								count3++;
							}
						}
					}
				}
			}
		}
	}

	if (count1 == 0)
	{
		perceivedCenter = currentPosition;
	}
	else
	{
		perceivedCenter /= count1;
	}

	if (count3 != 0)
	{
		perceivedVelocity /= count3;
	}

 	glm::vec3 finalSpeed = currentVelocity + (perceivedCenter - currentPosition)*rule1Scale + vectorC*rule2Scale + perceivedVelocity*rule3Scale;
	return finalSpeed;
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices, int* particleGridIndices/*I added this pointer*/,
  int* gridCellIndex,/*I added this pointer*/int gridSideCount, int gridCellWidth,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N)
	{
		return;
	}
	int boidIndex = particleArrayIndices[index];

	glm::vec3 updatedVel = newUpdateVelocity(N,index,boidIndex, pos, vel1, 
		particleArrayIndices,particleGridIndices,gridCellStartIndices,gridCellEndIndices,
		gridCellIndex,gridSideCount,gridCellWidth);

	//glm::vec3 updatedVel = UpdateVelocity8Grids(N, index, boidIndex, pos, vel1,
	//	particleArrayIndices, particleGridIndices, gridCellStartIndices, gridCellEndIndices,
	//	gridCellIndex, gridSideCount, gridCellWidth, gridMin);
		
	if (glm::length(updatedVel) > maxSpeed)
	{
		updatedVel = glm::normalize(updatedVel)*maxSpeed;
	}
	vel2[boidIndex] = updatedVel;
}


//TODO_2.2
__global__ void InitializeGridCellIndex(int* gridCellIndex,int gridSideCount)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= (gridSideCount*gridSideCount*gridSideCount))
	{
		return;
	}
	gridCellIndex[index] = -1;
}

//TODO_2.3
__global__ void RearangeVelAndPos(int N,int* particleArrayIndices, glm::vec3* pos, glm::vec3* vel,glm::vec3* arrPos, glm::vec3* arrVel)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N)
	{
		return;
	}

	int boidIndex = particleArrayIndices[index];
	glm::vec3 velocity = vel[boidIndex];
	glm::vec3 position = pos[boidIndex];

	arrPos[index] = position;
	arrVel[index] = velocity;
}

//TODO_2.3
__device__ glm::vec3 CoherentUpDateVelocity(int N, int index,  const glm::vec3 *pos, const glm::vec3 *vel, const int *particleArrayIndices,
	const int* particleGridIndices, int *gridCellStartIndices, int *gridCellEndIndices, int * gridCellIndex, int gridSideCount, int gridCellWidth)
{
	glm::vec3 currentPosition = pos[index];
	glm::vec3 currentVelocity = vel[index];

	int gridIndex = particleGridIndices[index];
	int gridIdx3Z = (int)gridIndex / (gridSideCount*gridSideCount);
	int gridIdx3Y = (int)((gridIndex - gridIdx3Z*gridSideCount*gridSideCount) / gridSideCount);
	int gridIdx3X = gridIndex - gridIdx3Z*gridSideCount*gridSideCount - gridIdx3Y*gridSideCount;
	//glm::vec3 gridIndex3D = gridIndex1Dto3D(gridIndex, gridSideCount);

	int startIndex = gridCellStartIndices[index];
	int endIndex = gridCellEndIndices[index];

	glm::vec3 perceivedCenter = glm::vec3(0.0f);
	int count1 = 0;
	glm::vec3 vectorC = glm::vec3(0.0f);
	glm::vec3 perceivedVelocity = glm::vec3(0.f);
	int count3 = 0;

	//add up the speed of boids in the same grid
	for (int i = startIndex;i <= endIndex;i++)
	{
		if (i != index)
		{
			glm::vec3 testPosition = pos[i];
			glm::vec3 testVelocity = vel[i];
			//rule1
			if (glm::length(testPosition - currentPosition) < rule1Distance)
			{
				perceivedCenter += testPosition;
				count1++;
			}

			//rule2
			if (glm::length(testPosition - currentPosition) < rule2Distance)
			{
				if (glm::length(testPosition - currentPosition) < 100.f)
				{
					vectorC -= (testPosition - currentPosition);
				}
			}

			//rule3
			if (glm::length(testPosition - currentPosition) < rule3Distance)
			{
				perceivedVelocity += testVelocity;
				count3++;
			}
		}
	}

	//test the neighboring grid cells 
	for (int j = (gridIdx3X - 1);j <= (gridIdx3X + 1);j++)
	{
		for (int k = (gridIdx3Y - 1);k <= (gridIdx3Y + 1);k++)
		{
			for (int m = (gridIdx3Z - 1);m <= gridIdx3Z + 1;m++)
			{
				//if 3D to 1D is -1 means the grid we are testing does not have 8 neighbors 
				int testGridIndexBeighbor = gridIndex3Dto1D(j, k, m, gridSideCount);
				if (testGridIndexBeighbor != -1)
				{
					//not the gridItself
					if (testGridIndexBeighbor != gridIndex)
					{
						//equals to -1 means there are not boids inside this grid cell
						if (gridCellIndex[testGridIndexBeighbor] != -1)
						{
							int startPoint = gridCellIndex[testGridIndexBeighbor];
							int endPoint = gridCellEndIndices[startPoint];
							for (int n = startPoint;n <= endPoint;n++)
							{
								glm::vec3 testPos = pos[n];
								glm::vec3 testVel = vel[n];

								//rule1
								if (glm::length(testPos - currentPosition) < rule1Distance)
								{
									perceivedCenter += testPos;
									count1++;
								}

								//rule2
								if (glm::length(testPos - currentPosition) < rule2Distance)
								{
									if (glm::length(testPos - currentPosition) < 100.f)
									{
										vectorC -= (testPos - currentPosition);
									}
								}

								//rule3
								if (glm::length(testPos - currentPosition) < rule3Distance)
								{
									perceivedVelocity += testVel;
									count3++;
								}
							}
						}
					}
				}
			}
		}
    }


//add up the speed of adjcent grids
    if (count1 == 0)
    {
	    perceivedCenter = currentPosition;
    }
    else
    {
	    perceivedCenter /= count1;
    }

    if (count3 != 0)
    {
	    perceivedVelocity /= count3;
    }
    glm::vec3 finalSpeed = currentVelocity + (perceivedCenter - currentPosition)*rule1Scale + vectorC*rule2Scale + perceivedVelocity*rule3Scale;
    return finalSpeed;
}


//TODO_2.3
__global__ void kernUpdateVelNeighborSearchCoherent(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int *gridCellStartIndices, int *gridCellEndIndices,
	int *particleArrayIndices, int* particleGridIndices/*I added this pointer*/,
	int* gridCellIndex,/*I added this pointer*/int gridSideCount, int gridCellWidth,
	glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N)
	{
		return;
	}

	glm::vec3 updateVel = CoherentUpDateVelocity(N, index,  pos, vel1,
		particleArrayIndices, particleGridIndices, gridCellStartIndices, gridCellEndIndices,
		gridCellIndex, gridSideCount, gridCellWidth);

	if (glm::length(updateVel) > maxSpeed)
	{
		updateVel = glm::normalize(updateVel)*maxSpeed;
	}
	vel2[index] = updateVel;

}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
	//cudaEvent_t beginEvent;
	//cudaEvent_t endEvent;

	//cudaEventCreate(&beginEvent);
	//cudaEventCreate(&endEvent);
	//cudaEventRecord(beginEvent, 0);

	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

	kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize >>>(numObjects, dev_pos, dev_vel1, dev_vel2);
	//char* cudaGetErrorString(cudaError_t);
	//printf("%s/n", cudaGetErrorString(cudaGetLastError()));
	cudaThreadSynchronize();

	kernUpdatePos<<<fullBlocksPerGrid, blockSize >>>(numObjects, dt, dev_pos, dev_vel2);
	cudaThreadSynchronize();

  // TODO-1.2 ping-pong the velocity buffers
	cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3)*numObjects, cudaMemcpyDeviceToDevice);
	cudaThreadSynchronize();

	//cudaEventRecord(endEvent, 0);
	//float timeValue;
	//cudaEventElapsedTime(&timeValue, beginEvent, endEvent);

	//std::cout << "Calculation time of this loop: " << timeValue << std::endl;
	//cudaEventDestroy(beginEvent);
	//cudaEventDestroy(endEvent);

}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	kernComputeIndices <<<fullBlocksPerGrid, blockSize >>> (numObjects, gridSideCount,gridMinimum,gridInverseCellWidth, dev_pos, devBoidIndex, devGridCellnumber);
	cudaThreadSynchronize();

	int threadsPerBlock = blockSize;
	int blockCount = floor((gridSideCount*gridSideCount*gridSideCount) / threadsPerBlock) + 1;

	InitializeGridCellIndex << <blockCount, threadsPerBlock >> > (gridCellIndex,gridSideCount);
	cudaThreadSynchronize();

	thrust::device_ptr<int> dev_thrust_keys(devGridCellnumber);
	thrust::device_ptr<int> dev_thrust_values(devBoidIndex);

	thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + numObjects, dev_thrust_values);

	//cudaFree(dev_intBoids);
	//cudaFree(dev_intGrids);
	//checkCUDAErrorWithLine("cudaFree failed!");

	//****************
	//other steps here 
	cudaThreadSynchronize();
	kernIdentifyCellStartEnd <<<fullBlocksPerGrid, blockSize >>> (numObjects, devGridCellnumber, dev_gridCellStartIndices, dev_gridCellEndIndices);
	cudaThreadSynchronize();
	
	renewGridCellIndex <<<fullBlocksPerGrid, blockSize >>> (numObjects, dev_gridCellStartIndices, gridCellIndex, devGridCellnumber);
    cudaThreadSynchronize();

	kernUpdateVelNeighborSearchScattered << <fullBlocksPerGrid, blockSize >> > (numObjects, gridSideCount,
		gridMinimum, gridInverseCellWidth, gridCellWidth, 
		dev_gridCellStartIndices, dev_gridCellEndIndices, 
		devBoidIndex,devGridCellnumber, gridCellIndex, 
		gridSideCount, gridCellWidth,
		dev_pos, dev_vel1, dev_vel2);
	cudaThreadSynchronize();

	//as usual down here
	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, dev_pos, dev_vel2);
	cudaThreadSynchronize();

	cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3)*numObjects, cudaMemcpyDeviceToDevice);
	cudaThreadSynchronize();
}


//TODO_2.3
void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.

	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	kernComputeIndices << <fullBlocksPerGrid, blockSize >> > (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos, devBoidIndex, devGridCellnumber);
	cudaThreadSynchronize();

	int threadsPerBlock = blockSize;
	int blockCount = floor((gridSideCount*gridSideCount*gridSideCount) / threadsPerBlock) + 1;

	InitializeGridCellIndex << <blockCount, threadsPerBlock >> > (gridCellIndex, gridSideCount);
	cudaThreadSynchronize();

	thrust::device_ptr<int> dev_thrust_keys(devGridCellnumber);
	thrust::device_ptr<int> dev_thrust_values(devBoidIndex);

	thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + numObjects, dev_thrust_values);

	cudaThreadSynchronize();
	kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (numObjects, devGridCellnumber, dev_gridCellStartIndices, dev_gridCellEndIndices);
	cudaThreadSynchronize();

	renewGridCellIndex << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_gridCellStartIndices, gridCellIndex, devGridCellnumber);
	cudaThreadSynchronize();

	 glm::vec3* rearrangePos;
	 glm::vec3* rearrangeVel;

	cudaMalloc((void**)& rearrangePos, sizeof(glm::vec3)*numObjects);
	cudaMalloc((void**)& rearrangeVel, sizeof(glm::vec3)*numObjects);

	RearangeVelAndPos << <fullBlocksPerGrid, blockSize >> >(numObjects, devBoidIndex, dev_pos, dev_vel1, rearrangePos, rearrangeVel);
	cudaThreadSynchronize();

	kernUpdateVelNeighborSearchCoherent << <fullBlocksPerGrid, blockSize >> > (numObjects, gridSideCount,
		gridMinimum, gridInverseCellWidth, gridCellWidth,
		dev_gridCellStartIndices, dev_gridCellEndIndices,
		devBoidIndex, devGridCellnumber, gridCellIndex,
		gridSideCount, gridCellWidth,
		rearrangePos, rearrangeVel, dev_vel2);

	//as usual down here
	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, rearrangePos, dev_vel2);
	cudaThreadSynchronize();


	cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3)*numObjects, cudaMemcpyDeviceToDevice);
	cudaThreadSynchronize();

	cudaMemcpy(dev_pos, rearrangePos, sizeof(glm::vec3)*numObjects, cudaMemcpyDeviceToDevice);
	cudaThreadSynchronize();

	cudaFree(rearrangePos);
	cudaFree(rearrangeVel);
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  //****************TODO2.1 cudaFree
  cudaFree(devGridCellnumber);
  cudaFree(devBoidIndex);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(gridCellIndex);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
